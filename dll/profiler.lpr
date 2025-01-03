library profiler;
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$pointermath on}
{$asmmode intel}

uses
  Classes, SysUtils,
  profiler_common,
  nodetree, nodeio
  ;

type
  generic TOnlyGrowArrayWithStableAddress<T> = class sealed
  type PT = ^T;
  const
    array_size = 1024*32;
    bucket_size = array_size;
  private
    cs: TRTLCriticalSection;
    arrays: array [0..bucket_size-1] of array of T;
  public
    constructor Create;
    destructor Destroy; override;
    function get(i: UInt32): PT; inline;
    function &set(i: UInt32; const value: T): PT; inline;
  end;

  generic TSimpleStack<T> = record
  type PT = ^T;
  const
    grow_size = 4096;
  private
    stack: PT;
    curr_pos: UInt32;
    curr_len: UInt32;
  public
    procedure Create; inline;
    procedure Free; inline;
    procedure push(const value: T); inline;
    function pop: T; inline;
    function top: PT; inline;
  end;

  TProfilerNode = specialize TNode<TProfilerNodeData, TNodeComparator, TSimpleAllocator>;

  TCallInfo = record
    node: TProfilerNode.PNode;
    t0: UInt64;
    t1: UInt64;
    prev_prof_inc: UInt64;
    prev_all: UInt64;
    no_calculate: Boolean;
  end;

  TCallStack = specialize TSimpleStack<TCallInfo>;

  PThreadData = ^TThreadData;
  TThreadData = record
    profiler_data: TProfilerNode.PNode;
    callstack: TCallStack;
  end;

  TThreads = specialize TOnlyGrowArrayWithStableAddress<TThreadData>;

threadvar
  thread_id: UInt32;

var
  ticks_per_second: UInt64;
  ProfilerState: Boolean = False;
  Threads: TThreads;
  //cs: TRTLCriticalSection;

  thread_counter: UInt32 = 0;  // возрастающий счётчик потоков
  init_thread_counter: UInt32; // для повторного запуска профайлера, уже не с 0 будет начинаться
                               // чтобы вычислсять старые потоки, у которых уже выставлен id в переменной потока!

function readtsc: UInt64; assembler; nostackframe;
asm
  rdtsc // p ?
  shl rdx, 32
  or rax, rdx
end;

procedure TSimpleStack.Create;
begin
  curr_pos:=0;
  curr_len:=grow_size;
  GetMem(stack, curr_len*SizeOf(T));
end;

procedure TSimpleStack.Free;
begin
  Freemem(stack);
end;

procedure TSimpleStack.push(const value: T);
begin
  if curr_pos=curr_len then
  begin
    curr_len+=grow_size;
    ReAllocMem(stack, curr_len*SizeOf(T));
  end;
  stack[curr_pos]:=value;
  inc(curr_pos);
end;

function TSimpleStack.pop: T;
begin
  dec(curr_pos);
  Result:=stack[curr_pos];
end;

function TSimpleStack.top: PT;
begin
  Result:=@stack[curr_pos-1];
end;

function TOnlyGrowArrayWithStableAddress.get(i: UInt32): PT;
var
  arr_index, index: UInt32;
begin
  arr_index := i div array_size;
  index := i mod array_size;

  Result:=@arrays[arr_index][index];
end;

function TOnlyGrowArrayWithStableAddress.&set(i: UInt32; const value: T): PT;
var
  arr_index, index: UInt32;
begin
  arr_index := i div array_size;
  index := i mod array_size;

  if Length(arrays[arr_index])=0 then
  begin
    EnterCriticalSection(cs);
    if Length(arrays[arr_index])=0 then SetLength(arrays[arr_index], array_size);
    LeaveCriticalSection(cs);
  end;

  arrays[arr_index][index]:=value;

  Result:=@arrays[arr_index][index];
end;

constructor TOnlyGrowArrayWithStableAddress.Create;
begin
  InitCriticalSection(cs);
end;

destructor TOnlyGrowArrayWithStableAddress.Destroy;
begin
  DoneCriticalSection(cs);
  inherited Destroy;
end;

function RegisterNewThread(new_thread_id: UInt32): PThreadData;
const
  frames_count = 1024; // надеюсь 1024 хватит для нового потока, не из жопы мира ведь они стартуют
var
  NewThreadData: TThreadData;
  node: TProfilerNode.PNode;

  i, count: SizeInt;
  frames: array [0..frames_count-1] of codepointer;

  call_info: TCallInfo;
begin
  NewThreadData.profiler_data:=TProfilerNode.NewNode;
  NewThreadData.callstack.Create;

  // root_node будет информационной нодой, для хранения ThreadID и т.п.
  NewThreadData.profiler_data^.NodeData.call_count:=GetCurrentThreadId;

  node:=NewThreadData.profiler_data;
  MyZeroMemory(call_info, SizeOf(call_info));
  call_info.node:=node;
  call_info.no_calculate:=True;
  NewThreadData.callstack.push(call_info);

  count:=CaptureBacktrace(3, frames_count-1, @frames[0]);
  for i:=count-1 downto 1 do // -1 - т.к. текущая функция уже попадает под калькуляцию
  begin
    node:=node^.AddChild;
    node^.NodeData.code_addr:=frames[i];
    MyZeroMemory(call_info, SizeOf(call_info));
    call_info.node:=node;
    call_info.no_calculate:=True;
    NewThreadData.callstack.push(call_info);
  end;

  Result:=Threads.&set(new_thread_id, NewThreadData);
end;

procedure _profiler_enter(addr: Pointer; rdtsc: UInt64);
var
  ThreadData: PThreadData;
  call_info: TCallInfo;
  node_: TProfilerNode.PNode;
  L_thread_id: UInt32;
  L_init_thread_counter: UInt32;
begin
  if not ProfilerState then Exit;

  L_thread_id:=thread_id;
  L_init_thread_counter:=init_thread_counter;
  // новый поток ?
  if (L_thread_id<=L_init_thread_counter) then
  begin
    L_thread_id:=InterlockedIncrement(thread_counter);
    ThreadData:=RegisterNewThread(L_thread_id-L_init_thread_counter);
    thread_id:=L_thread_id;
  end else
  begin
    ThreadData:=Threads.get(L_thread_id-L_init_thread_counter);
  end;

  node_:=ThreadData^.callstack.top^.node^.FindChild(addr);

  if node_=nil then
  begin
    node_:=ThreadData^.callstack.top^.node^.AddChild;
    with node_^.NodeData do
    begin
      {.}code_addr:=addr;
      {.}prof_exc_min:=High({.}prof_exc_min);
      {.}prof_inc_min:=High({.}prof_inc_min);
      {.}func_exc_min:=High({.}func_exc_min);
      {.}func_inc_min:=High({.}func_inc_min);
    end;
  end;

  MyZeroMemory(call_info, SizeOf(call_info));
  with ThreadData^.callstack do
  begin
    {.}push(call_info);
    with top^ do begin
      {.}node:=node_;
      {.}t0:=rdtsc;
      {.}t1:=readtsc;
    end;
  end;
end;


procedure _profiler_leave(dummy, rdtsc: UInt64);
var
  ThreadData: PThreadData;
  call_info: TCallInfo;
  func_inc, func_exc, prof_inc, prof_exc: UInt64;
  L_thread_id: UInt32;
  L_init_thread_counter: UInt32;
begin
  if not ProfilerState then Exit;

  // если поток ещё не был в enter - то игнорируем...
  L_thread_id:=thread_id;
  L_init_thread_counter:=init_thread_counter;
  if (L_thread_id<L_init_thread_counter) then Exit;

  ThreadData:=Threads.get(L_thread_id-L_init_thread_counter);

  if not ThreadData^.callstack.top^.no_calculate then
  begin
    call_info:=ThreadData^.callstack.pop;

    with call_info.node^.NodeData do
    begin
      inc({.}call_count);

      func_inc:=rdtsc - call_info.t1;
      {.}func_inc_sum+=func_inc;
      if {.}func_inc_max<func_inc then {.}func_inc_max:=func_inc;
      if {.}func_inc_min>func_inc then {.}func_inc_min:=func_inc;

      func_exc:=func_inc - call_info.prev_all;
      {.}func_exc_sum+=func_exc;
      if {.}func_exc_max<func_exc then {.}func_exc_max:=func_exc;
      if {.}func_exc_min>func_exc then {.}func_exc_min:=func_exc;

      prof_exc:=(call_info.t1 - call_info.t0) + (readtsc-rdtsc);
      {.}prof_exc_sum+=prof_exc;
      if {.}prof_exc_max<prof_exc then {.}prof_exc_max:=prof_exc;
      if {.}prof_exc_min>prof_exc then {.}prof_exc_min:=prof_exc;

      prof_inc:=prof_exc + call_info.prev_prof_inc;
      {.}prof_inc_sum+=prof_inc;
      if {.}prof_inc_max<prof_inc then {.}prof_inc_max:=prof_inc;
      if {.}prof_inc_min>prof_inc then {.}prof_inc_min:=prof_inc;
    end;

    with ThreadData^.callstack.top^ do
    begin
      {.}prev_prof_inc+=prof_inc;
      {.}prev_all+=readtsc-call_info.t0;
    end;
  end;
end;

procedure profiler_init;
const
  sleep_time = 3;
begin
  if ProfilerState then Exit;

  ticks_per_second := readtsc;
  sleep(sleep_time*1000);
  ticks_per_second:=(readtsc-ticks_per_second) div sleep_time;

  init_thread_counter:=thread_counter;
  WriteBarrier; // хз, вроде надо

  Threads:=TThreads.Create;

  ProfilerState:=True;
end;

procedure profiler_reset;
type
  TProfilerNodeIO = specialize TNodeIO<TProfilerNode.PNode>;
var
  i: UInt32;
  NodeSave: TProfilerNodeIO;
  RootNode: TProfilerNode.PNode;
begin
  if not ProfilerState then Exit;

  // Хм... может тут будет выгоднее поставить большой тайм-аут
  // т.е. 100% дать всем потокам выйти из обработчиков профайлера
  // и затем длеть дела?
  // не супер безопасно, но зато это позволит в обработчиках профайлера
  // сузить область критической секции до поиска/добавления ноды,
  // что само собой должно повысить производительность...
  // нужно это проверить когда всё будет готово
  //EnterCriticalSection();
  ProfilerState:=False;
  Sleep(1000); // умышленно так
  //LeaveCriticalSection();

  NodeSave:=TProfilerNodeIO.Create('', '.cpuprof');
  RootNode:=TProfilerNode.NewNode;
  RootNode^.NodeData.code_addr:=Pointer(ticks_per_second);
  for i:=1 to thread_counter-init_thread_counter do
  begin
    RootNode^.AddChild(Threads.get(i)^.profiler_data);
  end;
  NodeSave.SaveNode(RootNode);
  NodeSave.Free;

  RootNode^.FreeReqursive;

  for i:=init_thread_counter+1 to thread_counter do
  begin
    Threads.get(i)^.callstack.Free;
  end;

  Threads.Free;
end;


// Нужна более лучшая интеграция в FPC
// FPC знает в каких регистрах идут параметры
// поэтому генерацию сохранения и восстановление
// регистров нужно сделать на стороне FPC
procedure profiler_enter; assembler; nostackframe;
asm
  sub rsp, $A0

.seh_stackalloc $A0
.seh_endprologue

  mov [rsp+$00], rax
  mov [rsp+$08], rdx

  rdtsc
  shl rdx, 32
  or rdx, rax       // читаем RDTSC в RDX (второй аргумент)

  mov [rsp+$10], rcx
  mov [rsp+$18], r8
  mov [rsp+$20], r9
  mov [rsp+$28], r10
  mov [rsp+$30], r11
  movaps [rsp+$40], xmm0
  movaps [rsp+$50], xmm1
  movaps [rsp+$60], xmm2
  movaps [rsp+$70], xmm3
  movaps [rsp+$80], xmm4
  movaps [rsp+$90], xmm5

  mov rcx, [rsp+$A0] // читаем адрес возврата из стека в RCX (первый аргумент)
  call _profiler_enter

  // это будет неучтённая часть времени проведенного в профайлере для profiler_leave, с profiler_enter длолжно быть всё ок
  // она прибавится ко времени проведенному во функции... но не факт! можно исправить
  // вернув указатель на данные которые поправить в самый последний момент

  mov rax, [rsp+$00]
  mov rdx, [rsp+$08]
  mov rcx, [rsp+$10]
  mov r8,  [rsp+$18]
  mov r9,  [rsp+$20]
  mov r10, [rsp+$28]
  mov r11, [rsp+$30]
  movaps xmm0, [rsp+$40]
  movaps xmm1, [rsp+$50]
  movaps xmm2, [rsp+$60]
  movaps xmm3, [rsp+$70]
  movaps xmm4, [rsp+$80]
  movaps xmm5, [rsp+$90]

  add rsp, $A0
end;

// Здесь, думаю, тоже самое, местро хранения result известно
procedure profiler_leave; assembler; nostackframe;
asm
  sub rsp, $30

.seh_stackalloc $30
.seh_endprologue

  mov [rsp+$00], rax

  rdtsc
  shl rdx, 32
  or rdx, rax       // читаем RDTSC в RDX (второй аргумент)

  movaps [rsp+$10], xmm0
  movaps [rsp+$20], xmm1

  call _profiler_leave

  mov rax, [rsp+$00]
  movaps xmm0, [rsp+$10]
  movaps xmm1, [rsp+$20]

  add rsp, $30
end;


exports
   profiler_init
  ,profiler_enter
  ,profiler_leave
  ,profiler_reset;
end.

