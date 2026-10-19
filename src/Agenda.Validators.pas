unit Agenda.Validators;

{$I agenda.inc}

{ The API's validators, gathered in one factory (pascal-common-faa 1.21.0's
  PascalCommon.Validators), the partner of Agenda.Normalizers: TValid
  inherits TPcStringValidators, so TValid.Required, MaxLength, OneOf,
  FromFunc and All come from the library, next to this API's rules.

  Only what the OpenAPI document can't say is here. The limits it declares
  (TApiSchema.Describe in each unit: a name at most 100 characters, a
  duration from 5 to 480, a price from 0 to 100000, a password of at least 8,
  a role owner or staff) are enforced at the edge by pascal-api-infra-faa
  0.20.0's THorseBody.Read and THorseQueryParams.Read, on the value as it
  came; a limit is written once. The repositories normalize, then run these
  rules through TPcValidation, which checks an optional member only when it
  holds a value and raises every failing field in one 400.

  Until 2026-10-19 this API had Agenda.Validation: each rule written three
  times (a required string, an IOptString, an IOptNullString) and every
  limit a second time next to its Describe. }

interface

uses
  PascalCommon.Validators;

type
  TValid = class(TPcStringValidators)
  public
    /// A name with something besides blanks (its length is the document's).
    class function DisplayName: IPcStringValidator; static;
    /// An address: one "@" with text on both sides, no spaces, at most 254.
    class function Email: IPcStringValidator; static;
    /// "+" (optional) and 8 to 15 digits: TNorm.Phone's form of a real phone.
    class function Phone: IPcStringValidator; static;
  end;

implementation

uses
  SysUtils,
  Agenda.Text;

function CheckEmail(const AField, AValue: string; out AMessage: string): string;
begin
  Result := '';
  // NormalizeEmail answers '' for what can't be an address.
  if NormalizeEmail(AValue) = '' then
  begin
    Result := 'invalid_email';
    AMessage := Format('"%s" is not an email address.', [AField]);
  end;
end;

function CheckPhone(const AField, AValue: string; out AMessage: string): string;
begin
  Result := '';
  if (NormalizePhone(AValue) = '') or (NormalizePhone(AValue) <> AValue) then
  begin
    Result := 'invalid_phone';
    AMessage := Format('"%s" is not a phone number (8 to 15 digits).', [AField]);
  end;
end;

class function TValid.DisplayName: IPcStringValidator;
begin
  Result := Required;
end;

class function TValid.Email: IPcStringValidator;
begin
  Result := FromFunc(CheckEmail);
end;

class function TValid.Phone: IPcStringValidator;
begin
  Result := FromFunc(CheckPhone);
end;

end.
