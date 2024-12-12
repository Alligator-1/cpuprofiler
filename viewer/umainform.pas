unit umainform;
{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Generics.Collections, laz.VirtualTrees, nodetree, nodeio, profiler_common, math,
  FpDbgLoader, FpDbgDwarf, FpDbgInfo, FpDbgDwarfDataClasses, FpdMemoryTools, DbgIntfBaseTypes
  ;

type
  TAddrNameDict = specialize TDictionary<Pointer, String>;

  TProfilerNode = specialize TNode<TProfilerNodeData, TNodeComparator, TSimpleAllocator>;

  TProfilerNodeIO = specialize TNodeIO<TProfilerNode.PNode>;

  TMainForm = class(TForm)
    btnLoadExecutable: TButton;
    btnLoadCPUProfile: TButton;
    IdleTimer1: TIdleTimer;
    vt: TLazVirtualStringTree;
    OpenDialog: TOpenDialog;
    procedure btnLoadExecutableClick(Sender: TObject);
    procedure btnLoadCPUProfileClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure IdleTimer1Timer(Sender: TObject);
    procedure vtBeforeCellPaint(Sender: TBaseVirtualTree;
      TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex;
      CellPaintMode: TVTCellPaintMode; CellRect: TRect; var ContentRect: TRect);
    procedure vtCompareNodes(Sender: TBaseVirtualTree; Node1,
      Node2: PVirtualNode; Column: TColumnIndex; var Result: Integer);
    procedure vtDrawText(Sender: TBaseVirtualTree; TargetCanvas: TCanvas;
      Node: PVirtualNode; Column: TColumnIndex; const CellText: String;
      const CellRect: TRect; var DefaultDraw: Boolean);
    procedure vtExpanded(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure vtExpanding(Sender: TBaseVirtualTree; Node: PVirtualNode;
      var Allowed: Boolean);
    procedure vtGetText(Sender: TBaseVirtualTree; Node: PVirtualNode;
      Column: TColumnIndex; TextType: TVSTTextType; var CellText: String);
  private
    ImageLoaderList: TDbgImageLoaderList;
{$IF DECLARED(TFpDbgMemModel)}
    MemModel: TFpDbgMemModel;
{$ENDIF}
    DwarfInfo: TFpDwarfInfo;
    AddrNameDict: TAddrNameDict;
    ProfilerNode: TProfilerNode.PNode;
  public
    procedure LoadNode(const node: PVirtualNode);
    procedure LoadCPUProfile(filename: string);
    procedure OpenDWARF(filename: string);
    procedure CloseDWARF;
    function GetDWARFInfoByAddress(addr: Pointer): string;
  end;

const
  form_caption = 'CPU profiler viewer';
  s_not_found = '?';

var
  MainForm: TMainForm;
  ticks_per_second: UInt64 = 0;

implementation

{$R *.lfm}

procedure TMainForm.btnLoadCPUProfileClick(Sender: TObject);
begin
  if OpenDialog.Execute then LoadCPUProfile(OpenDialog.FileName);
end;

procedure TMainForm.btnLoadExecutableClick(Sender: TObject);
begin
  if OpenDialog.Execute then OpenDWARF(OpenDialog.FileName);
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  CloseDWARF;
  AddrNameDict.Free;
  ProfilerNode^.FreeReqursive;
end;

function ticks_to_time(ticks: UInt64): string;
var
  t: Double;
begin
  t:=ticks / ticks_per_second;
  if t >= 60.0 then
  begin
    Str(t/60.0:0:1, Result);
    Result+='m';
  end
  else if t >= 1.0 then
  begin
    Str(t:0:1, Result);
    Result+='s';
  end
  else if t >= 0.001 then
  begin
    Str(t*1000.0:0:1, Result);
    Result+='ms';
  end
  else if t >= 0.000001 then
  begin
    Str(t*1000000.0:0:1, Result);
    Result+='us';
  end
  else if t >= 0.000000001 then
  begin
    Str(t*1000000000.0:0:1, Result);
    Result+='ns';
  end else
  begin
    Result:='0ns';
  end;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  i: Integer;
begin
  vt.NodeDataSize:=SizeOf(Pointer);

  vt.TreeOptions.SelectionOptions:=vt.TreeOptions.SelectionOptions+[toFullRowSelect];
  vt.Header.MinHeight:=50;
  with vt.Header.Columns do
  begin
    Add.Text:='addr';              // 0
    Add.Text:='count';             // 1

    Add.Text:='func inc sum';      // 2
    Add.Text:='func inc avg';      // 3
    Add.Text:='func inc min';      // 4
    Add.Text:='func inc max';      // 5

    Add.Text:='func exc sum';      // 6
    Add.Text:='func exc avg';      // 7
    Add.Text:='func exc min';      // 8
    Add.Text:='func exc max';      // 9

    Add.Text:='prof inc sum';      // 10
    Add.Text:='prof inc avg';      // 11
    Add.Text:='prof inc min';      // 12
    Add.Text:='prof inc max';      // 13

    Add.Text:='prof exc sum';      // 14
    Add.Text:='prof exc avg';      // 15
    Add.Text:='prof exc min';      // 16
    Add.Text:='prof exc max';      // 17

    Add.Text:='name';              // 18
  end;
  for i:=0 to vt.Header.Columns.Count-1 do
  begin
    vt.Header.Columns.Items[i].Options:=vt.Header.Columns.Items[i].Options+[coWrapCaption];
    vt.Header.Columns.Items[i].MinWidth:=55;
    vt.Header.Columns.Items[i].Alignment:=taRightJustify;
    vt.Header.Columns.Items[i].CaptionAlignment:=taLeftJustify;
  end;
  vt.Header.Columns.Items[0].Alignment:=taLeftJustify;
  vt.Header.Columns.Items[18].Alignment:=taLeftJustify;

  vt.Header.Options:=vt.Header.Options+[hoVisible,hoDblClickResize,hoDisableAnimatedResize,hoHeaderClickAutoSort,hoHeightResize];
  vt.DefaultText:='';

  AddrNameDict:=TAddrNameDict.Create;

  ProfilerNode := TProfilerNode.NewNode;

  DwarfInfo:=nil;
{$IF DECLARED(TFpDbgMemModel)}
  MemModel:=nil;
{$ENDIF}
end;

procedure TMainForm.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  i: integer;
begin
  for i:=0 to Min(1, High(FileNames)) do
  begin
    case LowerCase(ExtractFileExt(FileNames[i])) of
      '.cpuprof': LoadCPUProfile(FileNames[i]);
      '.exe': OpenDWARF(FileNames[i]);
    end;
  end;
end;

procedure TMainForm.IdleTimer1Timer(Sender: TObject);
begin
  TIdleTimer(Sender).Enabled:=False;
  vt.Header.AutoFitColumns(False);
end;

procedure TMainForm.vtBeforeCellPaint(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; CellPaintMode: TVTCellPaintMode; CellRect: TRect; var ContentRect: TRect);
begin
  case Column of
    2..9: begin
            if vsSelected in Node^.States then TargetCanvas.Brush.Color:=$A5FFA5 else TargetCanvas.Brush.Color:=$DCFFDC;
            TargetCanvas.FillRect(CellRect);
          end;
    10..17: begin
            if vsSelected in Node^.States then TargetCanvas.Brush.Color:=$A5A5FF else TargetCanvas.Brush.Color:=$DCDCFF;
            TargetCanvas.FillRect(CellRect);
          end;
  end;
end;

generic function CompareValue<T>(const a, b: T): Integer; inline;
begin
  if a>b then Result:=1
  else if a<b then Result:=-1
  else Result:=0;
end;

procedure TMainForm.vtCompareNodes(Sender: TBaseVirtualTree; Node1, Node2: PVirtualNode; Column: TColumnIndex; var Result: Integer);
var
  pndt1, pndt2: TProfilerNode.PNodeData;
begin
  if not Column in [1..13] then Exit;

  pndt1:=@TProfilerNode.PNode(PPointer(Sender.GetNodeData(Node1))^)^.NodeData;
  pndt2:=@TProfilerNode.PNode(PPointer(Sender.GetNodeData(Node2))^)^.NodeData;

  case Column of
     1: Result:=specialize CompareValue<UInt64>(pndt1^.call_count, pndt2^.call_count);

     2: Result:=specialize CompareValue<UInt64>(pndt1^.func_inc_sum, pndt2^.func_inc_sum);
     3: Result:=specialize CompareValue<UInt64>(pndt1^.func_inc_avg, pndt2^.func_inc_avg);
     4: Result:=specialize CompareValue<UInt64>(pndt1^.func_inc_min, pndt2^.func_inc_min);
     5: Result:=specialize CompareValue<UInt64>(pndt1^.func_inc_max, pndt2^.func_inc_max);

     6: Result:=specialize CompareValue<UInt64>(pndt1^.func_exc_sum, pndt2^.func_exc_sum);
     7: Result:=specialize CompareValue<UInt64>(pndt1^.func_exc_avg, pndt2^.func_exc_avg);
     8: Result:=specialize CompareValue<UInt64>(pndt1^.func_exc_min, pndt2^.func_exc_min);
     9: Result:=specialize CompareValue<UInt64>(pndt1^.func_exc_max, pndt2^.func_exc_max);

     10: Result:=specialize CompareValue<UInt64>(pndt1^.prof_inc_sum, pndt2^.prof_inc_sum);
     11: Result:=specialize CompareValue<UInt64>(pndt1^.prof_inc_avg, pndt2^.prof_inc_avg);
     12: Result:=specialize CompareValue<UInt64>(pndt1^.prof_inc_min, pndt2^.prof_inc_min);
     13: Result:=specialize CompareValue<UInt64>(pndt1^.prof_inc_max, pndt2^.prof_inc_max);

     14: Result:=specialize CompareValue<UInt64>(pndt1^.prof_exc_sum, pndt2^.prof_exc_sum);
     15: Result:=specialize CompareValue<UInt64>(pndt1^.prof_exc_avg, pndt2^.prof_exc_avg);
     16: Result:=specialize CompareValue<UInt64>(pndt1^.prof_exc_min, pndt2^.prof_exc_min);
     17: Result:=specialize CompareValue<UInt64>(pndt1^.prof_exc_max, pndt2^.prof_exc_max);
  end;
end;

procedure TMainForm.vtDrawText(Sender: TBaseVirtualTree; TargetCanvas: TCanvas; Node: PVirtualNode; Column: TColumnIndex; const CellText: String; const CellRect: TRect; var DefaultDraw: Boolean);
begin
  TargetCanvas.Font.Color:=clBlack;
end;

procedure TMainForm.vtExpanded(Sender: TBaseVirtualTree; Node: PVirtualNode);
begin
  with Sender do
    if (ChildCount[Node]=1) and (([vsToggling,vsExpanded] * GetFirstChild(Node)^.States)=[]) then ToggleNode(GetFirstChild(Node));

  IdleTimer1.Enabled:=True;
end;

procedure TMainForm.vtExpanding(Sender: TBaseVirtualTree; Node: PVirtualNode; var Allowed: Boolean);
begin
  with Sender do
    if HasChildren[Node] and (GetFirstChild(Node)=nil) then LoadNode(Node);
end;

procedure TMainForm.vtGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex; TextType: TVSTTextType; var CellText: String);
var
  pndt: TProfilerNode.PNodeData;
begin
  pndt:=@TProfilerNode.PNode(PPointer(Sender.GetNodeData(Node))^)^.NodeData;

  case Column of
     0: CellText:=IntToHex(PtrUInt(pndt^.code_addr)).TrimLeft('0');
     1: CellText:=UIntToStr(pndt^.call_count);

     2: CellText:=ticks_to_time(pndt^.func_inc_sum);
     3: CellText:=ticks_to_time(pndt^.func_inc_avg);
     4: CellText:=ticks_to_time(pndt^.func_inc_min);
     5: CellText:=ticks_to_time(pndt^.func_inc_max);

     6: CellText:=ticks_to_time(pndt^.func_exc_sum);
     7: CellText:=ticks_to_time(pndt^.func_exc_avg);
     8: CellText:=ticks_to_time(pndt^.func_exc_min);
     9: CellText:=ticks_to_time(pndt^.func_exc_max);

     10: CellText:=ticks_to_time(pndt^.prof_inc_sum);
     11: CellText:=ticks_to_time(pndt^.prof_inc_avg);
     12: CellText:=ticks_to_time(pndt^.prof_inc_min);
     13: CellText:=ticks_to_time(pndt^.prof_inc_max);

     14: CellText:=ticks_to_time(pndt^.prof_exc_sum);
     15: CellText:=ticks_to_time(pndt^.prof_exc_avg);
     16: CellText:=ticks_to_time(pndt^.prof_exc_min);
     17: CellText:=ticks_to_time(pndt^.prof_exc_max);

     18: CellText:=GetDWARFInfoByAddress(pndt^.code_addr);
    else CellText:='huh?';
  end;
end;

procedure TMainForm.LoadNode(const node: PVirtualNode);
var
  pvn: PVirtualNode;
  pnd: TProfilerNode.PNode;
begin
  pnd:=PPointer(vt.GetNodeData(node))^;

  vt.BeginUpdate;

  pnd:=pnd^.Child;

  while Assigned(pnd) do
  begin
    pvn:=vt.AddChild(node, pnd);
    vt.HasChildren[pvn]:=Assigned(pnd^.Child);
    pnd:=pnd^.Sibling;
  end;

  vt.EndUpdate;
end;

procedure TMainForm.OpenDWARF(filename: string);
begin
  CloseDWARF;

  ImageLoaderList := TDbgImageLoaderList.Create(True);
  TDbgImageLoader.Create(filename).AddToLoaderList(ImageLoaderList);

{$IF DECLARED(TFpDbgMemModel)}
  MemModel := TFpDbgMemModel.Create;
  DwarfInfo := TFpDwarfInfo.Create(ImageLoaderList, nil, MemModel);
{$ELSE}
  DwarfInfo := TFpDwarfInfo.Create(ImageLoaderList, nil);
{$ENDIF}

  DwarfInfo.LoadCompilationUnits;
end;

procedure TMainForm.CloseDWARF;
begin
{$IF DECLARED(TFpDbgMemModel)}
  MemModel.Free;
  MemModel:=nil;
{$ENDIF}
  DwarfInfo.Free;
  DwarfInfo:=nil;
  ImageLoaderList.Free;
  ImageLoaderList:=nil;
end;

function TMainForm.GetDWARFInfoByAddress(addr: Pointer): string;
var
  addr_info: TFpSymbol;
  source, hs: string;
  line: LongWord;
begin
  if AddrNameDict.ContainsKey(addr) then
  begin
    Result:=AddrNameDict.Items[addr];
    Exit;
  end;

  if not Assigned(DwarfInfo) then Exit(s_not_found);

  addr_info:=DwarfInfo.FindProcSymbol(TDBGPtr(addr));
  if Assigned(addr_info) then
  begin
    Result:=addr_info.Name;
    line:=addr_info.Line;
    source:=addr_info.FileName;

    addr_info.ReleaseReference;

    if source<>'' then
    begin
      if line<>0 then
      begin
        str(line, hs);
        Result:=Result + ' line ' + hs + ' of ' + source;
      end else
      begin
        Result:=Result + ' of ' + source;
      end;
    end;
  end else Result:=s_not_found;

  AddrNameDict.Add(addr, Result);
end;

procedure TMainForm.LoadCPUProfile(filename: string);
var
  pvn: PVirtualNode;
  NodeLoader: TProfilerNodeIO;
begin
  AddrNameDict.Clear;
  vt.Clear;

  NodeLoader:=TProfilerNodeIO.Create(filename,'');
  NodeLoader.LoadNode(ProfilerNode);
  NodeLoader.Free;

  Caption:=form_caption + '[' + filename + ']';

  pvn:=vt.AddChild(nil, ProfilerNode);
  vt.HasChildren[pvn]:=Assigned(ProfilerNode^.Child);

  ticks_per_second:=UInt64(ProfilerNode^.NodeData.code_addr);

  LoadNode(pvn);

  vt.Header.AutoFitColumns(False);
end;


end.

