unit Agenda.Text;

{$I agenda.inc}

{ Phone numbers as people type them (their digits, the stored form), an
  email address's normalized form, and a list's search as its LIKE pattern.

  The search key and the LIKE pattern that lived here moved to the libraries
  (2026-10-19): pascal-common-faa 1.20.0's PcFoldForSearch and pascal-db-faa
  0.16.0's PdbLikeContains. A phone stayed: pascal-common-faa's normalizers
  leave business rules (a CEP, a CPF, a phone) to the application. }

interface

uses
  PascalCommon.Optionals;

/// True when AText looks like a phone number as people type one: digits,
/// spaces, "-", ".", "(", ")", and "+" only first; at least one digit.
/// ADigits gets the digits alone ("+55 (11) 9999-0000" -> "551199990000").
function TryPhoneDigits(const AText: string; out ADigits: string): Boolean;

/// The stored form of a phone: "+" (when typed first) and 8 to 15 digits
/// (E.164's maximum); '' when AText isn't one.
function NormalizePhone(const AText: string): string;

/// Trimmed and lower-cased (ASCII); '' when it can't be an address (one "@"
/// with text on both sides, no spaces, at most 254 characters). The login
/// compares emails through it.
function NormalizeEmail(const AEmail: string): string;

/// The LIKE pattern of a list's search (pascal-db-faa's PdbLikeContains),
/// ASearch already normalized the way the column was (folded, lower case);
/// absent when the search is absent or nothing is left of it. For
/// TQueryArgs.OptStrings, which drops the block of an absent filter.
function SearchPattern(const ASearch: IOptString): IOptString;

implementation

uses
  SysUtils,
  PascalDb.SqlLoader;

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

function NormalizeEmail(const AEmail: string): string;
var
  P: Integer;
begin
  Result := LowerCase(Trim(AEmail));
  P := Pos('@', Result);
  if (P < 2) or (P = Length(Result)) or (Length(Result) > 254) or
    (Pos('@', Copy(Result, P + 1, MaxInt)) > 0) or (Pos(' ', Result) > 0) then
    Result := '';
end;

function SearchPattern(const ASearch: IOptString): IOptString;
begin
  Result := TOptionals.Map(TOptionals.UndefinedIfEmpty(ASearch), PdbLikeContains);
end;

end.
