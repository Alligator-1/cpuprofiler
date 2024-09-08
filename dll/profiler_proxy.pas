unit profiler_proxy;
{$mode objfpc}

interface

const profiler_dll = 'profiler.dll';

procedure profiler_init; external profiler_dll name 'profiler_init';
procedure profiler_reset; external profiler_dll name 'profiler_reset';

procedure profiler_enter; public name 'profiler_enter';
procedure profiler_leave; public name 'profiler_leave';

implementation

procedure _profiler_enter; external profiler_dll name 'profiler_enter';
procedure _profiler_leave; external profiler_dll name 'profiler_leave';

procedure profiler_enter; assembler; nostackframe;
asm
  jmp _profiler_enter
end;

procedure profiler_leave; assembler; nostackframe;
asm
  jmp _profiler_leave
end;

end.

