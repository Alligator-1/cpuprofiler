unit profiler_proxy;
{$mode objfpc}
{$define NOPROFILING}

interface

const
  profiler_dll = 'profiler.dll';

var
  LibHandle: TLibHandle;
  profiler_enter: TProcedure=TProcedure(Pointer($10101010)); public name 'profiler_enter';
  profiler_leave: TProcedure=TProcedure(Pointer($20202020)); public name 'profiler_leave';

procedure profiler_init; external profiler_dll name 'profiler_init';
procedure profiler_reset; external profiler_dll name 'profiler_reset';

implementation

initialization
  LibHandle:=LoadLibrary(profiler_dll);
  profiler_enter:=TProcedure(GetProcAddress(LibHandle, 'profiler_enter'));
  profiler_leave:=TProcedure(GetProcAddress(LibHandle, 'profiler_leave'));

end.
