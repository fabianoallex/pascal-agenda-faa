unit Agenda.Normalizers;

{$I agenda.inc}

{ The API's normalizers, gathered in one factory: TNorm inherits
  pascal-common-faa's TPcStringNormalizers, so TNorm.Trim, Lower,
  FoldForSearch, FromFunc and Chain come from the library and typing "TNorm."
  lists this API's rules next to them (pascal-api-infra-faa's sample 02 and
  its guide "DTOs and JSON" do the same).

  A normalizer only changes a present value into the form the API stores:
  it never refuses one. A value that can't be made right (a phone with
  letters, a name of spaces) comes out as it went in, or empty, and
  Agenda.Validation refuses it next. Kept apart on purpose: a normalizer that
  cut a name at 100 characters would hide the client's mistake instead of
  answering 400.

  The repositories apply them inside the optionals, so an absent member
  stays absent without an if:
    LName := TOptionals.Normalize(APatch.Name, TNorm.PersonName);
  and to a plain value with Apply: TNorm.Email.Apply(AUser.Email). }

interface

uses
  PascalCommon.Normalizers;

type
  TNorm = class(TPcStringNormalizers)
  public
    /// Runs of blanks inside the text become one space.
    class function CollapseSpaces: IPcStringNormalizer; static;
    /// A person's or a service's name: trimmed, inner runs of blanks collapsed.
    class function DisplayName: IPcStringNormalizer; static;
    /// An email address: trimmed and lower case.
    class function Email: IPcStringNormalizer; static;
    /// A phone typed with spaces, "-", ".", "(" or ")": "+" (when first) and
    /// its digits; any other text as it came (Agenda.Validation refuses it).
    class function Phone: IPcStringNormalizer; static;
  end;

implementation

uses
  SysUtils,
  Agenda.Text;

function CollapseSpacesOf(const AValue: string): string;
var
  I: Integer;
  LSpace: Boolean;
begin
  Result := '';
  LSpace := False;
  for I := 1 to Length(AValue) do
    if CharInSet(AValue[I], [' ', #9, #10, #13]) then
      LSpace := True
    else
    begin
      if LSpace and (Result <> '') then
        Result := Result + ' ';
      LSpace := False;
      Result := Result + AValue[I];
    end;
end;

function PhoneOf(const AValue: string): string;
var
  LDigits: string;
begin
  if not TryPhoneDigits(AValue, LDigits) then
    Exit(AValue);
  if Trim(AValue)[1] = '+' then
    Result := '+' + LDigits
  else
    Result := LDigits;
end;

class function TNorm.CollapseSpaces: IPcStringNormalizer;
begin
  Result := FromFunc(CollapseSpacesOf);
end;

class function TNorm.DisplayName: IPcStringNormalizer;
begin
  Result := Chain([Trim, CollapseSpaces]);
end;

class function TNorm.Email: IPcStringNormalizer;
begin
  Result := Chain([Trim, Lower]);
end;

class function TNorm.Phone: IPcStringNormalizer;
begin
  Result := FromFunc(PhoneOf);
end;

end.
