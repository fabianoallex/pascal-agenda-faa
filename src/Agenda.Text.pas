unit Agenda.Text;

{$I agenda.inc}

{ Phone numbers as people type them: their digits, and the stored form.

  The search key and the LIKE pattern that lived here moved to the libraries
  (2026-10-19): pascal-common-faa 1.20.0's PcFoldForSearch and pascal-db-faa
  0.16.0's PdbLikeContains. A phone stayed: pascal-common-faa's normalizers
  leave business rules (a CEP, a CPF, a phone) to the application. }

interface

/// True when AText looks like a phone number as people type one: digits,
/// spaces, "-", ".", "(", ")", and "+" only first; at least one digit.
/// ADigits gets the digits alone ("+55 (11) 9999-0000" -> "551199990000").
function TryPhoneDigits(const AText: string; out ADigits: string): Boolean;

/// The stored form of a phone: "+" (when typed first) and 8 to 15 digits
/// (E.164's maximum); '' when AText isn't one.
function NormalizePhone(const AText: string): string;

implementation

uses
  SysUtils;

// Phones are ASCII: indexing string is the same on both compilers here (a
// non-ASCII byte or unit is refused either way).
function TryPhoneDigits(const AText: string; out ADigits: string): Boolean;
var
  LText: string;
  I: Integer;
begin
  ADigits := '';
  LText := Trim(AText);
  Result := False;
  for I := 1 to Length(LText) do
    case LText[I] of
      '0'..'9': ADigits := ADigits + LText[I];
      ' ', '-', '.', '(', ')': ;
      '+':
        if I > 1 then
          Exit;
    else
      Exit;
    end;
  Result := ADigits <> '';
end;

function NormalizePhone(const AText: string): string;
var
  LDigits: string;
begin
  Result := '';
  if not TryPhoneDigits(AText, LDigits) then
    Exit;
  if (Length(LDigits) < 8) or (Length(LDigits) > 15) then
    Exit;
  if Trim(AText)[1] = '+' then
    Result := '+' + LDigits
  else
    Result := LDigits;
end;

end.
