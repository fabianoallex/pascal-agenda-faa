unit Agenda.SignedLinks;

{$I agenda.inc}

{ Signed links: a URL that grants one thing (see or cancel one appointment)
  until an expiry, with no account behind it. The signature is HMAC-SHA256
  over

    agenda-link|v1|<scope>|<purpose>|<resource>|<expires>

  and travels as "<key id>.<signature in Base64url>", so the keys can rotate:
  links signed with an older key verify while that key is configured.

  The keys come from one setting in JWT_KEYS_MASTER_KEY's format, entries
  "id:<Base64 of at least 32 bytes>" separated by ",": the first one signs,
  every one verifies. Each scope (a tenant) gets its own key, derived as
  HMAC(key, "agenda-link-key|<scope>"): a link of one tenant never verifies
  for another, and no stored secret is needed per tenant.

  Not the JWT key ring (docs/design.md, M3 decision 1): a ring's key stops
  verifying minutes after the next one signs, and the ring rotates every 30
  days, while a link may have to live as long as the appointment is ahead.

  - Verify takes the signature only in its canonical Base64url (what Sign
    writes): the last character of 32 bytes carries 4 bits, and without
    this check "...A" and "...B" verified alike.
  - Verify checks the signature before the expiry: lsExpired is only ever
    told to someone holding a valid link. It compares in constant time and
    never raises on what a client sent.
  - Scope, purpose and resource are part of the signed text, separated by
    "|": none may contain one (ESignedLinkError on Sign; a Verify for one
    answers lsMalformed).
  - Pure: no clock (the caller passes now), no HTTP.

  A library candidate (docs/design.md, "PascalApi.SignedUrl"), written
  under the libraries' rules so it can move as it is. }

interface

uses
  SysUtils;

const
  /// A key shorter than this is refused (HMAC-SHA256's own output size).
  SIGNED_LINK_MIN_KEY_BYTES = 32;
  /// A key id: 1 to 16 of A-Z a-z 0-9 _ - (no ".": it ends the id in a
  /// signature).
  SIGNED_LINK_MAX_KEY_ID = 16;

type
  ESignedLinkError = class(Exception);

  TSignedLinkCheck = (lsOk, lsMalformed, lsUnknownKey, lsBadSignature, lsExpired);

  TSignedLinks = class
  private type
    TLinkKey = record
      Id: string;
      Key: TBytes;
    end;
  private
    FKeys: array of TLinkKey;
    function IndexOfKey(const AId: string): Integer;
    function Mac(AIndex: Integer; const AScope, APurpose, AResource: string;
      AExpires: Int64): TBytes;
  public
    /// AKeys: the setting's format (the unit's comment). ESignedLinkError
    /// for no key, an invalid or repeated id, a key that isn't Base64 or is
    /// shorter than SIGNED_LINK_MIN_KEY_BYTES; the message never shows a key.
    constructor Create(const AKeys: string);
    /// "<key id>.<signature>", with the first key. ESignedLinkError for a
    /// part with "|", an empty scope or purpose, or AExpires below 0.
    function Sign(const AScope, APurpose, AResource: string; AExpires: Int64): string;
    /// ASignature as Sign wrote it, for the same parts; ANow in the same
    /// unit as AExpires (Unix seconds). lsExpired when ANow >= AExpires.
    function Verify(const AScope, APurpose, AResource: string; AExpires: Int64;
      const ASignature: string; ANow: Int64): TSignedLinkCheck;
    /// "exp=<expires>&sig=<signature>": the query of a link.
    function Query(const AScope, APurpose, AResource: string; AExpires: Int64): string;
    /// The id of the key that signs.
    function SigningKeyId: string;
  end;

/// Reads a link's "exp" parameter: digits only (no sign, no spaces), at most
/// 18 of them. False otherwise.
function TryParseLinkExpiry(const AText: string; out AExpires: Int64): Boolean;

implementation

uses
  PascalCommon.Version,
  PascalCommon.Crypto,
  PascalCommon.Utf8;

{$IF PASCALCOMMON_VERSION < 11700}
  {$MESSAGE FATAL 'Agenda.SignedLinks needs pascal-common-faa 1.17.0 or later (PascalCommon.Crypto)'}
{$IFEND}

const
  SIGNED_TEXT_PREFIX = 'agenda-link|v1|';
  DERIVE_PREFIX = 'agenda-link-key|';

function KeyIdIsValid(const AId: string): Boolean;
var
  I: Integer;
begin
  Result := (AId <> '') and (Length(AId) <= SIGNED_LINK_MAX_KEY_ID);
  if not Result then
    Exit;
  for I := 1 to Length(AId) do
    if not CharInSet(AId[I], ['A'..'Z', 'a'..'z', '0'..'9', '_', '-']) then
      Exit(False);
end;

// Standard Base64 (as "openssl rand -base64 32" writes it) or Base64url,
// with or without padding.
function DecodeAnyBase64(const AText: string; out ABytes: TBytes): Boolean;
var
  LText: string;
  I: Integer;
begin
  LText := AText;
  for I := 1 to Length(LText) do
    if LText[I] = '+' then
      LText[I] := '-'
    else if LText[I] = '/' then
      LText[I] := '_';
  Result := (LText <> '') and PcBase64UrlDecode(LText, ABytes);
end;

function TryParseLinkExpiry(const AText: string; out AExpires: Int64): Boolean;
var
  I: Integer;
begin
  AExpires := 0;
  Result := (AText <> '') and (Length(AText) <= 18);
  if not Result then
    Exit;
  for I := 1 to Length(AText) do
  begin
    if not CharInSet(AText[I], ['0'..'9']) then
      Exit(False);
    AExpires := AExpires * 10 + (Ord(AText[I]) - Ord('0'));
  end;
end;

{ TSignedLinks }

constructor TSignedLinks.Create(const AKeys: string);
var
  LRest, LEntry, LId, LKeyText: string;
  LComma, LColon: Integer;
  LKey: TBytes;
begin
  inherited Create;
  LRest := Trim(AKeys);
  while LRest <> '' do
  begin
    LComma := Pos(',', LRest);
    if LComma = 0 then
    begin
      LEntry := Trim(LRest);
      LRest := '';
    end
    else
    begin
      LEntry := Trim(Copy(LRest, 1, LComma - 1));
      LRest := Trim(Copy(LRest, LComma + 1, MaxInt));
      if LRest = '' then
        raise ESignedLinkError.Create('Link keys: an empty entry after the last ","');
    end;
    LColon := Pos(':', LEntry);
    if LColon = 0 then
      raise ESignedLinkError.CreateFmt('Link keys: entry %d is not id:key', [Length(FKeys) + 1]);
    LId := Trim(Copy(LEntry, 1, LColon - 1));
    LKeyText := Trim(Copy(LEntry, LColon + 1, MaxInt));
    if not KeyIdIsValid(LId) then
      raise ESignedLinkError.CreateFmt('Link keys: entry %d has an invalid id ' +
        '(1 to %d of A-Z a-z 0-9 _ -)', [Length(FKeys) + 1, SIGNED_LINK_MAX_KEY_ID]);
    if IndexOfKey(LId) >= 0 then
      raise ESignedLinkError.CreateFmt('Link keys: id "%s" appears twice', [LId]);
    if not DecodeAnyBase64(LKeyText, LKey) or (Length(LKey) < SIGNED_LINK_MIN_KEY_BYTES) then
      raise ESignedLinkError.CreateFmt('Link keys: key "%s" is not Base64 of at least %d bytes',
        [LId, SIGNED_LINK_MIN_KEY_BYTES]);
    SetLength(FKeys, Length(FKeys) + 1);
    FKeys[High(FKeys)].Id := LId;
    FKeys[High(FKeys)].Key := LKey;
  end;
  if Length(FKeys) = 0 then
    raise ESignedLinkError.Create('Link keys: no key');
end;

function TSignedLinks.IndexOfKey(const AId: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FKeys) do
    if FKeys[I].Id = AId then
      Exit(I);
  Result := -1;
end;

function TSignedLinks.Mac(AIndex: Integer; const AScope, APurpose, AResource: string;
  AExpires: Int64): TBytes;
var
  LScopeKey: TBytes;
begin
  LScopeKey := PcDigestToBytes(PcHmacSha256(FKeys[AIndex].Key,
    PcStringToUtf8Bytes(DERIVE_PREFIX + AScope)));
  Result := PcDigestToBytes(PcHmacSha256(LScopeKey, PcStringToUtf8Bytes(SIGNED_TEXT_PREFIX +
    AScope + '|' + APurpose + '|' + AResource + '|' + IntToStr(AExpires))));
end;

function PartsAreValid(const AScope, APurpose, AResource: string; AExpires: Int64): Boolean;
begin
  Result := (AScope <> '') and (APurpose <> '') and (AExpires >= 0) and
    (Pos('|', AScope) = 0) and (Pos('|', APurpose) = 0) and (Pos('|', AResource) = 0);
end;

function TSignedLinks.Sign(const AScope, APurpose, AResource: string; AExpires: Int64): string;
begin
  if not PartsAreValid(AScope, APurpose, AResource, AExpires) then
    raise ESignedLinkError.Create('TSignedLinks.Sign: an empty scope or purpose, a "|" in a ' +
      'part, or an expiry below 0');
  Result := FKeys[0].Id + '.' + PcBase64UrlEncode(Mac(0, AScope, APurpose, AResource, AExpires));
end;

function TSignedLinks.Verify(const AScope, APurpose, AResource: string; AExpires: Int64;
  const ASignature: string; ANow: Int64): TSignedLinkCheck;
var
  LDot, LIndex: Integer;
  LGiven: TBytes;
begin
  if not PartsAreValid(AScope, APurpose, AResource, AExpires) then
    Exit(lsMalformed);
  LDot := Pos('.', ASignature);
  if (LDot <= 1) or not KeyIdIsValid(Copy(ASignature, 1, LDot - 1)) or
    not PcBase64UrlDecode(Copy(ASignature, LDot + 1, MaxInt), LGiven) or
    (Length(LGiven) <> 32) then
    Exit(lsMalformed);
  // Only the canonical text: the last of 43 characters carries 4 bits, so
  // other spellings decode to the same bytes (measured: "...A" and "...B"
  // were one signature). One link, one spelling.
  if PcBase64UrlEncode(LGiven) <> Copy(ASignature, LDot + 1, MaxInt) then
    Exit(lsMalformed);
  LIndex := IndexOfKey(Copy(ASignature, 1, LDot - 1));
  if LIndex < 0 then
    Exit(lsUnknownKey);
  if not PcSameBytes(LGiven, Mac(LIndex, AScope, APurpose, AResource, AExpires)) then
    Exit(lsBadSignature);
  if ANow >= AExpires then
    Exit(lsExpired);
  Result := lsOk;
end;

function TSignedLinks.Query(const AScope, APurpose, AResource: string; AExpires: Int64): string;
begin
  // Base64url and the key id need no escaping in a query.
  Result := 'exp=' + IntToStr(AExpires) + '&sig=' + Sign(AScope, APurpose, AResource, AExpires);
end;

function TSignedLinks.SigningKeyId: string;
begin
  Result := FKeys[0].Id;
end;

end.
