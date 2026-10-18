unit Agenda.Passwords;

{$I agenda.inc}

{ Password hashing: PBKDF2-HMAC-SHA256 (RFC 8018), a random salt per
  password, and a self-describing stored form, so the cost can grow later
  without invalidating the hashes already stored:

    $pbkdf2-sha256$i=<iterations>$<salt>$<hash>

  salt (16 bytes) and hash (32 bytes) in Base64url without padding. The
  password is hashed as UTF-8 bytes, the same on both compilers.

  PBKDF2 itself is pascal-common-faa's PcPbkdf2HmacSha256 (1.18.0, written
  there for this unit: the fast form needs SHA-256's private compression);
  this unit adds the stored form, the salt (PascalCommon.Random) and the
  checks. A library candidate (docs/design.md), written under the
  libraries' rules, so it can move to pascal-common-faa as it is.

  - Verify compares in constant time and answers False for anything it can't
    read (another scheme, a cut string): it never raises on stored data.
  - NeedsRehash says when a stored hash used fewer iterations than now: the
    login re-hashes it while it has the password in hand.
  - The cost doesn't grow with the password's length: a key longer than
    HMAC's block is hashed once, before the iterations (RFC 2104).
  - DEFAULT_PASSWORD_ITERATIONS is below OWASP's 600,000 on purpose: pure
    Pascal SHA-256 runs 600,000 iterations in about 0.8 s (FPC 3.2.2 Win64
    -O2, measured), 210,000 in about 0.26 s. The stored form keeps the
    count, so raising it later re-hashes each password at its next login.
  - MAX_PASSWORD_BYTES bounds what the server accepts at all.

  Not here: the policy (minimum length, which characters), and making an
  unknown user cost as much as a wrong password (the login does that, by
  verifying against a dummy hash). }

interface

uses
  SysUtils;

const
  /// About 0.26 s per hash (see above); OWASP's 2023 figure is 600,000.
  DEFAULT_PASSWORD_ITERATIONS = 210000;
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
  PascalCommon.Version,
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalCommon.Utf8;

{$IF PASCALCOMMON_VERSION < 11800}
  {$MESSAGE FATAL 'Agenda.Passwords needs pascal-common-faa 1.18.0 or later (PcPbkdf2HmacSha256)'}
{$IFEND}

type
  TStoredHash = record
    Iterations: Integer;
    Salt: TBytes;
    Hash: TBytes;
  end;

function PasswordBytes(const APassword: string): TBytes;
begin
  Result := PcStringToUtf8Bytes(APassword);
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
    PcBase64UrlEncode(PcPbkdf2HmacSha256(PasswordBytes(APassword), ASalt, AIterations,
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
  LPassword := PcStringToUtf8Bytes(APassword);
  if (Length(LPassword) = 0) or (Length(LPassword) > MAX_PASSWORD_BYTES) then
    Exit;
  Result := PcSameBytes(PcPbkdf2HmacSha256(LPassword, LStored.Salt, LStored.Iterations,
    PASSWORD_HASH_BYTES), LStored.Hash);
end;

class function TPasswords.NeedsRehash(const AStored: string; AIterations: Integer): Boolean;
var
  LStored: TStoredHash;
begin
  Result := not TryParse(AStored, LStored) or (LStored.Iterations < AIterations);
end;

end.
