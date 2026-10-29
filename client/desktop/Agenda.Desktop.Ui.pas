unit Agenda.Desktop.Ui;

{ Small touches the screens share, the same on the VCL and the LCL. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Controls, StdCtrls, Graphics;
  {$ELSE}
  Vcl.Controls, Vcl.StdCtrls, Vcl.Graphics;
  {$ENDIF}

/// Every TLabel under AParent drawn in the middle of its height, so it
/// lines up with the edit next to it (OPCB gives a label its row's height).
procedure CenterLabels(AParent: TWinControl);

implementation

procedure CenterLabels(AParent: TWinControl);
var
  I: Integer;
begin
  for I := 0 to AParent.ControlCount - 1 do
    if AParent.Controls[I] is TLabel then
    begin
      // AutoSize would shrink it back to the text's height, at the top.
      TLabel(AParent.Controls[I]).AutoSize := False;
      TLabel(AParent.Controls[I]).Layout := tlCenter;
    end
    else if AParent.Controls[I] is TWinControl then
      CenterLabels(TWinControl(AParent.Controls[I]));
end;

end.
