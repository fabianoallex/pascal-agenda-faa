unit Agenda.Text;

{$I agenda.inc}

{ Text for searching: a key that ignores case and Latin accents, and a LIKE
  pattern that matches a client's text literally.

  SQLite's LOWER and LIKE fold ASCII only ("Á" stays "Á"), and PostgreSQL's
  depend on the collation, so a name is searched through a key the
  application computes once and stores next to it (NAME_KEY): lower case,
  and the accents of Latin-1 and Latin Extended-A letters removed ("São
  Conceição" -> "sao conceicao"). The same function folds what the client
  types, so both sides meet on the same text, on every database.

  The work is done on UTF-16 (UnicodeString) on both compilers: Length and
  indexing count UTF-16 units on Delphi and bytes on FPC, so a loop over
  string would see "ã" as one character on Delphi and two on FPC. On FPC the
  conversion needs the process code page to be UTF-8
  (SetMultiByteConversionCodePage(CP_UTF8), done by every program here).

  A library candidate (docs/design.md): pascal-common-faa has normalizers
  but no accent folding. }

interface

/// Lower case, Latin accents removed, spaces trimmed and runs of spaces made
/// one: the search key of a name.
function FoldForSearch(const AText: string): string;

/// '%<text>%' for LIKE ... ESCAPE '\', with %, _ and \ of AText escaped, so
/// the client's text matches literally (a "%" typed finds a "%").
function LikeContains(const AFolded: string): string;

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

function FoldChar(C: WideChar): WideChar;
begin
  case Ord(C) of
    Ord('A')..Ord('Z'): Result := WideChar(Ord(C) + 32);
    $00C0..$00C5, $00E0..$00E5, $0100..$0105: Result := 'a';
    $00C7, $00E7, $0106..$010D: Result := 'c';
    $010E..$0111: Result := 'd';
    $00C8..$00CB, $00E8..$00EB, $0112..$011B: Result := 'e';
    $011C..$0123: Result := 'g';
    $0124..$0127: Result := 'h';
    $00CC..$00CF, $00EC..$00EF, $0128..$0131: Result := 'i';
    $0134, $0135: Result := 'j';
    $0136, $0137: Result := 'k';
    $0139..$0142: Result := 'l';
    $00D1, $00F1, $0143..$0148: Result := 'n';
    $00D2..$00D6, $00D8, $00F2..$00F6, $00F8, $014C..$0151: Result := 'o';
    $0154..$0159: Result := 'r';
    $015A..$0161: Result := 's';
    $0162..$0167: Result := 't';
    $00D9..$00DC, $00F9..$00FC, $0168..$0173: Result := 'u';
    $0174, $0175: Result := 'w';
    $00DD, $00FD, $00FF, $0176..$0178: Result := 'y';
    $0179..$017E: Result := 'z';
  else
    Result := C;
  end;
end;

function FoldForSearch(const AText: string): string;
var
  LIn, LOut: UnicodeString;
  I, N: Integer;
  C: WideChar;
  LSpace: Boolean;
begin
  LIn := UnicodeString(AText);
  LOut := '';
  SetLength(LOut, Length(LIn));
  N := 0;
  LSpace := False;
  for I := 1 to Length(LIn) do
  begin
    C := FoldChar(LIn[I]);
    if (C = ' ') or (C = #9) or (C = #10) or (C = #13) then
    begin
      LSpace := N > 0;
      Continue;
    end;
    if LSpace then
    begin
      Inc(N);
      LOut[N] := ' ';
      LSpace := False;
    end;
    Inc(N);
    LOut[N] := C;
  end;
  SetLength(LOut, N);
  Result := string(LOut);
end;

function LikeContains(const AFolded: string): string;
var
  I: Integer;
begin
  Result := '%';
  for I := 1 to Length(AFolded) do
  begin
    if (AFolded[I] = '%') or (AFolded[I] = '_') or (AFolded[I] = '\') then
      Result := Result + '\';
    Result := Result + AFolded[I];
  end;
  Result := Result + '%';
end;

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
