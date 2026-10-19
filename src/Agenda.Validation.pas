unit Agenda.Validation;

{$I agenda.inc}

{ The checks shared by the repositories: each refuses a value with a 400
  (pascal-api-infra-faa's EValidationException) and changes nothing.
  Normalizing is Agenda.Normalizers' job, done first; a check sees the value
  as it will be stored.

  Every rule has an overload per shape a member can have, so a repository
  calls it the same way for each and never opens an optional:
    - string: a required member, always checked;
    - IOptString: checked when it came;
    - IOptNullString: checked when it came with a value (null clears it).
  The "if HasValue" lives here, once per rule. }

interface

uses
  PascalCommon.Optionals;

const
  MAX_NAME_CHARS = 100;

/// Required: something besides blanks, at most MAX_NAME_CHARS characters.
procedure ValidateName(const AName: string); overload;
procedure ValidateName(const AName: IOptString); overload;

/// An address: one "@" with text on both sides, no spaces, at most 254.
procedure ValidateEmail(const AEmail: string); overload;
procedure ValidateEmail(const AEmail: IOptString); overload;
procedure ValidateEmail(const AEmail: IOptNullString); overload;

/// "+" (optional) and 8 to 15 digits: TNorm.Phone's form of a real phone.
procedure ValidatePhone(const APhone: string); overload;
procedure ValidatePhone(const APhone: IOptString); overload;
procedure ValidatePhone(const APhone: IOptNullString); overload;

implementation

uses
  SysUtils,
  PascalCommon.Text,
  PascalApi.Http,
  PascalApi.Text,
  Agenda.Text;

procedure ValidateName(const AName: string);
begin
  if PcFoldForSearch(AName) = '' then
    raise EValidationException.Create('"name" is required.', 'name_required');
  if PaCharCount(AName) > MAX_NAME_CHARS then
    raise EValidationException.CreateFmt('"name" must have at most %d characters.',
      [MAX_NAME_CHARS]);
end;

procedure ValidateName(const AName: IOptString);
begin
  if AName.HasValue then
    ValidateName(AName.Value);
end;

procedure ValidateEmail(const AEmail: string);
begin
  // NormalizeEmail answers '' for what can't be an address.
  if NormalizeEmail(AEmail) = '' then
    raise EValidationException.Create('"email" is not an email address.');
end;

procedure ValidateEmail(const AEmail: IOptString);
begin
  if AEmail.HasValue then
    ValidateEmail(AEmail.Value);
end;

procedure ValidateEmail(const AEmail: IOptNullString);
begin
  if AEmail.HasValue and not AEmail.IsNull then
    ValidateEmail(AEmail.Value);
end;

procedure ValidatePhone(const APhone: string);
begin
  if (NormalizePhone(APhone) = '') or (NormalizePhone(APhone) <> APhone) then
    raise EValidationException.Create('"phone" is not a phone number (8 to 15 digits).');
end;

procedure ValidatePhone(const APhone: IOptString);
begin
  if APhone.HasValue then
    ValidatePhone(APhone.Value);
end;

procedure ValidatePhone(const APhone: IOptNullString);
begin
  if APhone.HasValue and not APhone.IsNull then
    ValidatePhone(APhone.Value);
end;

end.
