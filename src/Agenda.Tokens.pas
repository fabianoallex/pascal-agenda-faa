unit Agenda.Tokens;

{$I agenda.inc}

{ Ids and refresh tokens: what Agenda.Auth generates and reads, without a
  database, so it can be tested alone.

  A refresh token is "<tenant>.<secret>": the tenant id in clear, then 32
  random bytes in Base64url (43 characters). The tenant is in clear so that
  the lookup can go through the tenant filter like every other query (the
  rule of pascal-api-infra-faa's multi-tenancy): the server checks the tenant
  against the catalog first (a suspended tenant is refused before any
  query), then looks the token up in that tenant's rows. Only its SHA-256
  is stored: a copy of the table gives nobody a usable token.

  Ids are 16 random bytes as 32 lower-case hex digits: the same on every
  database, no sequence to read back after an INSERT. }

interface

uses
  SysUtils;

const
  REFRESH_SECRET_BYTES = 32;
  /// Base64url of 32 bytes, no padding.
  REFRESH_SECRET_CHARS = 43;
  MAX_TENANT_ID_LENGTH = 40;

/// 32 lower-case hex digits from the system's random source.
function NewId: string;

/// 1 to 40 characters of a-z, 0-9 and '-': the catalog's rule for an id.
function IsTenantId(const AText: string): Boolean;

/// A new token for ATenant (which must pass IsTenantId).
function NewRefreshToken(const ATenant: string): string;

/// False unless AToken is "<tenant>.<secret>" with a valid tenant id and a
/// secret of exactly 32 bytes in Base64url; ATenant is filled only then.
function TryParseRefreshToken(const AToken: string; out ATenant: string): Boolean;

/// What is stored: the SHA-256 of the whole token, as 64 hex digits.
function RefreshTokenHash(const AToken: string): string;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Random,
  PascalCommon.Utf8;

function NewId: string;
begin
  Result := LowerCase(PcBytesToHex(PcRandomBytes(16)));
end;

function IsTenantId(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (Length(AText) >= 1) and (Length(AText) <= MAX_TENANT_ID_LENGTH);
  if Result then
    for I := 1 to Length(AText) do
      if not CharInSet(AText[I], ['a'..'z', '0'..'9', '-']) then
        Exit(False);
end;

function NewRefreshToken(const ATenant: string): string;
begin
  if not IsTenantId(ATenant) then
    raise EArgumentException.CreateFmt('Not a tenant id: "%s".', [ATenant]);
  Result := ATenant + '.' + PcBase64UrlEncode(PcRandomBytes(REFRESH_SECRET_BYTES));
end;

function TryParseRefreshToken(const AToken: string; out ATenant: string): Boolean;
var
  P: Integer;
  LTenant, LSecret: string;
  LBytes: TBytes;
begin
  Result := False;
  ATenant := '';
  P := Pos('.', AToken);
  if P = 0 then
    Exit;
  LTenant := Copy(AToken, 1, P - 1);
  LSecret := Copy(AToken, P + 1, MaxInt);
  if not IsTenantId(LTenant) or (Length(LSecret) <> REFRESH_SECRET_CHARS) then
    Exit;
  if not PcBase64UrlDecode(LSecret, LBytes) or (Length(LBytes) <> REFRESH_SECRET_BYTES) then
    Exit;
  ATenant := LTenant;
  Result := True;
end;

function RefreshTokenHash(const AToken: string): string;
begin
  Result := LowerCase(PcBytesToHex(PcDigestToBytes(PcSha256(PcStringToUtf8Bytes(AToken)))));
end;

end.
