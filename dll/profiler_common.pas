unit profiler_common;
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

type
  PProfilerNodeData = ^TProfilerNodeData;
  TProfilerNodeData = packed record
    call_count,
    prof_exc_sum, prof_exc_min, prof_exc_max,
    prof_inc_sum, prof_inc_min, prof_inc_max,
    func_exc_sum, func_exc_min, func_exc_max,
    func_inc_sum, func_inc_min, func_inc_max: UInt64;
    code_addr: CodePointer;
    function prof_exc_avg: UInt64; inline;
    function prof_inc_avg: UInt64; inline;
    function func_exc_avg: UInt64; inline;
    function func_inc_avg: UInt64; inline;
  end;

implementation

function TProfilerNodeData.prof_exc_avg: UInt64;
begin
  if call_count>0 then result:=prof_exc_sum div call_count else result:=0;
end;

function TProfilerNodeData.prof_inc_avg: UInt64;
begin
  if call_count>0 then result:=prof_inc_sum div call_count else result:=0;
end;

function TProfilerNodeData.func_exc_avg: UInt64;
begin
  if call_count>0 then result:=func_exc_sum div call_count else result:=0;
end;

function TProfilerNodeData.func_inc_avg: UInt64;
begin
  if call_count>0 then result:=func_inc_sum div call_count else result:=0;
end;

end.

