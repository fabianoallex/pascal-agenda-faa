unit Agenda.Desktop.LoginForm;

{ The login dialog: built in code with OPCB (CreateNew, no .dfm/.lfm), the
  same source on the VCL and the LCL. It only shows TLoginModel's state and
  passes the user's input and clicks on; the model does the rest.

  ShowModal returns mrOk once logged in (the model's OnLoggedIn). Logging
  in again after a lost session: the model made with CreateAgain, the
  server and the company not editable. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Forms, Classes, Controls, StdCtrls, ExtCtrls, Graphics,
  {$ELSE}
  Vcl.Forms, System.Classes, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  {$ENDIF}
  SysUtils,
  OPCB,
  Agenda.Desktop.Ui,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Login;

type
  TLoginForm = class(TForm)
  private
    FModel: TLoginModel;
    FServer: TEdit;
    FTenant: TEdit;
    FEmail: TEdit;
    FPassword: TEdit;
    FStatus: TLabel;
    FOk: TButton;
    FCancel: TButton;
    FRendering: Boolean;
    procedure Render(Sender: TObject);
    procedure LoggedIn(Sender: TObject);
    procedure InputChanged(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    /// AModel is the caller's (not freed here).
    constructor CreateFor(AOwner: TComponent; AModel: TLoginModel);
  end;

implementation

constructor TLoginForm.CreateFor(AOwner: TComponent; AModel: TLoginModel);
var
  LCreator: TControlCreator;
begin
  inherited CreateNew(AOwner);
  FModel := AModel;
  Caption := 'Agenda: log in';
  BorderStyle := bsDialog;
  Position := poScreenCenter;
  LCreator := TControlCreator.Create;
  try
    LCreator
      .SetOwnerAndParent(Self, Self)
      .SetTopLeft(12, 12)
      .SetControlHeight(23)
      .GridInit(4, 2)
      .GridSetCellWidthAndHeight(240, 30)
      .GridSetColWidth(0, 80)
      .GridCellStrechHorizontal
      .Add(TControlBuilder.Create(TLabel).WithCaption('Server'))
      .Add(TControlBuilder.Create(TEdit, 'edtServer', FServer))
      .Add(TControlBuilder.Create(TLabel).WithCaption('Company'))
      .Add(TControlBuilder.Create(TEdit, 'edtTenant', FTenant))
      .Add(TControlBuilder.Create(TLabel).WithCaption('Email'))
      .Add(TControlBuilder.Create(TEdit, 'edtEmail', FEmail))
      .Add(TControlBuilder.Create(TLabel).WithCaption('Password'))
      .Add(TControlBuilder.Create(TEdit, 'edtPassword', FPassword))
      .GridFinish
      .SetDirection(cpdHorizontal)
      .BreakLine(4)
      .Add(TControlBuilder.Create(TLabel, 'lblStatus', FStatus).WithCaption('').WithWidth(320))
      .BreakLine(8)
      .IncLeft(152)
      .Add(TControlBuilder.Create(TButton, 'btnOk', FOk).WithCaption('Log in').WithWidth(80)
        .WithOnClick(OkClick))
      .Add(TControlBuilder.Create(TButton, 'btnCancel', FCancel).WithCaption('Cancel')
        .WithWidth(80))
      .RecalcParentSize(12, 12);
  finally
    LCreator.Free;
  end;
  // AutoSize off first: WordWrap set while AutoSize is on shrinks the empty
  // label to the width of a space (VCL), one letter per line afterwards.
  FStatus.AutoSize := False;
  FStatus.WordWrap := True;
  FStatus.Height := 30;
  CenterLabels(Self);
  FStatus.Layout := tlTop;
  FPassword.PasswordChar := '*';
  FOk.Default := True;
  FCancel.Cancel := True;
  FCancel.ModalResult := mrCancel;
  FServer.Text := FModel.Server;
  FTenant.Text := FModel.Tenant;
  FEmail.Text := FModel.Email;
  FPassword.Text := FModel.Password;
  FServer.OnChange := InputChanged;
  FTenant.OnChange := InputChanged;
  FEmail.OnChange := InputChanged;
  FPassword.OnChange := InputChanged;
  OnCloseQuery := HandleCloseQuery;
  FModel.OnChange := Render;
  FModel.OnLoggedIn := LoggedIn;
  if FModel.Again then
  begin
    Caption := 'Agenda: your session ended, log in again';
    FServer.Enabled := False;
    FTenant.Enabled := False;
    ActiveControl := FPassword;
  end;
  Render(nil);
end;

procedure TLoginForm.Render(Sender: TObject);
begin
  FRendering := True;
  try
    FOk.Enabled := FModel.CanSubmit;
    if FModel.Busy then
    begin
      FStatus.Font.Color := clWindowText;
      FStatus.Caption := 'Logging in...';
      Screen.Cursor := crHourGlass;
    end
    else
    begin
      Screen.Cursor := crDefault;
      FStatus.Font.Color := clRed;
      FStatus.Caption := FModel.Error.Text;
    end;
    if FPassword.Text <> FModel.Password then
      FPassword.Text := FModel.Password;
  finally
    FRendering := False;
  end;
end;

procedure TLoginForm.InputChanged(Sender: TObject);
begin
  if FRendering then
    Exit;
  // Only the field that changed: each assignment renders, and a render
  // shows the model's values in the others.
  if Sender = FServer then
    FModel.Server := FServer.Text
  else if Sender = FTenant then
    FModel.Tenant := FTenant.Text
  else if Sender = FEmail then
    FModel.Email := FEmail.Text
  else if Sender = FPassword then
    FModel.Password := FPassword.Text;
end;

procedure TLoginForm.OkClick(Sender: TObject);
begin
  FModel.Submit;
end;

procedure TLoginForm.LoggedIn(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TLoginForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // A login still running finishes first (its Done needs the model).
  CanClose := not FModel.Busy;
  if CanClose then
  begin
    FModel.OnChange := nil;
    FModel.OnLoggedIn := nil;
    Screen.Cursor := crDefault;
  end;
end;

end.
