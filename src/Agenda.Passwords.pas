unit Agenda.Passwords;

{$I agenda.inc}

{ Password hashing: PBKDF2-HMAC-SHA256 (RFC 8018), a random salt per
  password, and a self-describing stored form, so the cost can grow later
  without invalidating the hashes already stored:

    $pbkdf2-sha256$i=<iterations>$<salt>$<hash>

  salt (16 bytes) and hash (32 bytes) in Base64url without padding. The
  password is hashed as UTF-8 bytes, the same on both compilers.

  A library candidate (docs/design.md): built on pascal-common-faa's
  PascalCommon.Crypto (HMAC-SHA256, Base64url, a constant-time comparison)
  and PascalCommon.Random (the system's random source), and written under
  the libraries' rules, so it can move to pascal-common-faa as it is.

  - Verify compares in constant time and answers False for anything it can't
    read (another scheme, a cut string): it never raises on stored data.
  - NeedsRehash says when a stored hash used fewer iterations than now: the
    login re-hashes it while it has the password in hand.
  - A password longer than 64 bytes is hashed once before PBKDF2 starts:
    HMAC does exactly that to a long key (RFC 2104), so the result is the
    same, and the cost doesn't grow with the password's length.
  - MAX_PASSWORD_BYTES bounds what the server accepts at all.

  Not here: the policy (minimum length, which characters), and making an
  unknown user cost as much as a wrong password (the login does that, by
  verifying against a dummy hash). }

interface

uses
  SysUtils;

const
  /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256.
  DEFAULT_PASSWORD_ITERATIONS = 600000;
  /// A stored hash asking for more is refused (it would hold the server).
  MAX_PASSWORD_ITERATIONS = 10000000;
  MAX_PASSWORD_BYTES = 1024;
  PASSWORD_SALT_BYTES = 16;
  PASSWORD_HASH_BYTES = 32;
  PASSWORD_SCHEME = 'pbkdf2-sha256';

type
  EPasswordError = class(Exception);

  TPasswords = record
  public
    /// PBKDF2-HMAC-SHA256 itself (RFC 8018 section 5.2). Raises
    /// EArgumentException for fewer than 1 iteration or a length below 1.
    class function Pbkdf2Sha256(const APassword, ASalt: TBytes;
      AIterations, ALength: Integer): TBytes; static;
    /// A new stored form, with a new random salt. Raises EPasswordError for
    /// an empty password or one longer than MAX_PASSWORD_BYTES (UTF-8).
    class function Hash(const APassword: string;
      AIterations: Integer = DEFAULT_PASSWORD_ITERATIONS): string; static;
    /// The same stored form for a given salt (tests, and nothing else).
    class function HashWithSalt(const APassword: string; const ASalt: TBytes;
      AIterations: Integer): string; static;
    /// True only when AStored is this scheme and APassword matches it.
    class function Verify(const APassword, AStored: string): Boolean; static;
    /// True when AStored can't be read or used fewer than AIterations.
    class function NeedsRehash(const AStored: string;
      AIterations: Integer = DEFAULT_PASSWORD_ITERATIONS): Boolean; static;
  end;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalApi.Text;

const
  HMAC_BLOCK_BYTES = 64;

type
  TStoredHash = record
    Iterations: Integer;
    Salt: TBytes;
    Hash: TBytes;
  end;

class function TPasswords.Pbkdf2Sha256(const APassword, ASalt: TBytes;
  AIterations, ALength: Integer): TBytes;
var
  LKey, LBlock, LNext: TBytes;
  LU, LT: TPcSha256Digest;
  LBlocks, LBlockIndex, LDone, LCount, I, J: Integer;
begin
  if AIterations < 1 then
    raise EArgumentException.Create('PBKDF2: iterations must be 1 or more.');
  if ALength < 1 then
    raise EArgumentException.Create('PBKDF2: length must be 1 or more.');
  // HMAC hashes a key longer than its block first: doing it once here gives
  // the same result and keeps every iteration at one block of key.
  if Length(APassword) > HMAC_BLOCK_BYTES then
    LKey := PcDigestToBytes(PcSha256(APassword))
  else
    LKey := APassword;
  Result := nil;
  SetLength(Result, ALength);
  LBlocks := (ALength + 31) div 32;
  LDone := 0;
  for LBlockIndex := 1 to LBlocks do
  begin
    // U1 = HMAC(P, S || INT(i)), i as 32 bits big-endian.
    LBlock := nil;
    SetLength(LBlock, Length(ASalt) + 4);
    if Length(ASalt) > 0 then
      Move(ASalt[0], LBlock[0], Length(ASalt));
    LBlock[Length(ASalt)] := Byte(LBlockIndex shr 24);
    LBlock[Length(ASalt) + 1] := Byte(LBlockIndex shr 16);
    LBlock[Length(ASalt) + 2] := Byte(LBlockIndex shr 8);
    LBlock[Length(ASalt) + 3] := Byte(LBlockIndex);
    LU := PcHmacSha256(LKey, LBlock);
    LT := LU;
    LNext := nil;
    SetLength(LNext, 32);
    for I := 2 to AIterations do
    begin
      Move(LU[0], LNext[0], 32);
      LU := PcHmacSha256(LKey, LNext);
      for J := 0 to 31 do
        LT[J] := LT[J] xor LU[J];
    end;
    LCount := ALength - LDone;
    if LCount > 32 then
      LCount := 32;
    Move(LT[0], Result[LDone], LCount);
    Inc(LDone, LCount);
  end;
end;

function PasswordBytes(const APassword: string): TBytes;
begin
  Result := PaStringToUtf8Bytes(APassword);
  if Length(Result) = 0 then
    raise EPasswordError.Create('The password is empty.');
  if Length(Result) > MAX_PASSWORD_BYTES then
    raise EPasswordError.CreateFmt('The password is longer than %d bytes.', [MAX_PASSWORD_BYTES]);
end;

class function TPasswords.HashWithSalt(const APassword: string; const ASalt: TBytes;
  AIterations: Integer): string;
begin
  if (AIterations < 1) or (AIterations > MAX_PASSWORD_ITERATIONS) then
    raise EArgumentException.CreateFmt('Password iterations must be 1 to %d.',
      [MAX_PASSWORD_ITERATIONS]);
  Result := '$' + PASSWORD_SCHEME + '$i=' + IntToStr(AIterations) + '$' +
    PcBase64UrlEncode(ASalt) + '$' +
    PcBase64UrlEncode(Pbkdf2Sha256(PasswordBytes(APassword), ASalt, AIterations,
      PASSWORD_HASH_BYTES));
end;

class function TPasswords.Hash(const APassword: string; AIterations: Integer): string;
begin
  Result := HashWithSalt(APassword, PcRandomBytes(PASSWORD_SALT_BYTES), AIterations);
end;

// Splits off the text up to the next '$' (or the end); False when there is
// nothing left.
function NextField(var ARest: string; out AField: string): Boolean;
var
  P: Integer;
begin
  Result := ARest <> '';
  if not Result then
    Exit;
  P := Pos('$', ARest);
  if P = 0 then
  begin
    AField := ARest;
    ARest := '';
  end
  else
  begin
    AField := Copy(ARest, 1, P - 1);
    ARest := Copy(ARest, P + 1, MaxInt);
  end;
end;

function DigitsOnly(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (AText <> '') and (Length(AText) <= 9);
  for I := 1 to Length(AText) do
    if (AText[I] < '0') or (AText[I] > '9') then
      Exit(False);
end;

// '$pbkdf2-sha256$i=N$salt$hash', nothing more, nothing less.
function TryParse(const AStored: string; out AHash: TStoredHash): Boolean;
var
  LRest, LField, LSalt, LHash, LIterations: string;
begin
  Result := False;
  if (Length(AStored) < 2) or (AStored[1] <> '$') then
    Exit;
  LRest := Copy(AStored, 2, MaxInt);
  if not NextField(LRest, LField) or (LField <> PASSWORD_SCHEME) then
    Exit;
  if not NextField(LRest, LField) or (Copy(LField, 1, 2) <> 'i=') then
    Exit;
  LIterations := Copy(LField, 3, MaxInt);
  if not DigitsOnly(LIterations) then
    Exit;
  AHash.Iterations := StrToInt(LIterations);
  if (AHash.Iterations < 1) or (AHash.Iterations > MAX_PASSWORD_ITERATIONS) then
    Exit;
  if not NextField(LRest, LSalt) or not NextField(LRest, LHash) or (LRest <> '') then
    Exit;
  if (Pos('$', LHash) > 0) or not PcBase64UrlDecode(LSalt, AHash.Salt) or
    not PcBase64UrlDecode(LHash, AHash.Hash) then
    Exit;
  Result := (Length(AHash.Salt) > 0) and (Length(AHash.Hash) = PASSWORD_HASH_BYTES);
end;

class function TPasswords.Verify(const APassword, AStored: string): Boolean;
var
  LStored: TStoredHash;
  LPassword: TBytes;
begin
  Result := False;
  if not TryParse(AStored, LStored) then
    Exit;
  LPassword := PaStringToUtf8Bytes(APassword);
  if (Length(LPassword) = 0) or (Length(LPassword) > MAX_PASSWORD_BYTES) then
    Exit;
  Result := PcSameBytes(Pbkdf2Sha256(LPassword, LStored.Salt, LStored.Iterations,
    PASSWORD_HASH_BYTES), LStored.Hash);
end;

class function TPasswords.NeedsRehash(const AStored: string; AIterations: Integer): Boolean;
var
  LStored: TStoredHash;
begin
  Result := not TryParse(AStored, LStored) or (LStored.Iterations < AIterations);
end;

end.
