unit Agenda.Preconditions;

{$I agenda.inc}

{ Optimistic concurrency over HTTP: an entity tag made from a row's version,
  and the If-Match check (RFC 9110, section 13.1.1; 428 from RFC 6585).

  - The tag is the version in quotes, a strong validator: "3". A client that
    read the version from a list (the body carries it) can build it too.
  - If-Match is "*" or a list of entity tags. It matches when one of them is
    strongly equal to the current tag: a weak tag (W/"3") never matches.
  - The application's policy: a change needs If-Match (absent: 428), with
    the tag the client read; "*" only when the caller accepts it (it says
    nothing about which version was read). A header that isn't the RFC's
    syntax is a 400; a tag that isn't the current one, a 412.

  A library candidate (PascalApi.Http plus a middleware, docs/design.md): no
  Horse, no database, written under the libraries' rules. }

interface

const
  CODE_PRECONDITION_REQUIRED = 'precondition_required';
  CODE_PRECONDITION_FAILED = 'precondition_failed';
  CODE_INVALID_IF_MATCH = 'invalid_if_match';

type
  TIfMatchResult = (
    imAbsent,   // no header, or only blanks
    imAny,      // "*"
    imMatch,    // a tag strongly equal to the current one
    imNoMatch,  // valid, but no tag matches
    imInvalid   // not the RFC's syntax
  );

/// '"<version>"': a strong entity tag.
function VersionETag(AVersion: Int64): string;

/// What AHeader (If-Match's value) says about ACurrentETag (a strong tag,
/// quotes included). ACurrentETag '' only checks the syntax: imMatch never.
function EvaluateIfMatch(const AHeader, ACurrentETag: string): TIfMatchResult;

/// Before reading the row: 428 when AHeader is absent (or "*" and not
/// AAcceptAny), 400 when it isn't valid. EHttpException.
procedure RequireIfMatchSent(const AHeader: string; AAcceptAny: Boolean = False);

/// RequireIfMatchSent, then 412 unless AHeader matches ACurrentETag.
procedure RequireIfMatch(const AHeader, ACurrentETag: string; AAcceptAny: Boolean = False);

/// The 412 for a write guarded by the version read that matched no row:
/// the resource changed after the check.
procedure RaisePreconditionFailed;

implementation

uses
  SysUtils,
  PascalApi.Http;

function VersionETag(AVersion: Int64): string;
begin
  Result := '"' + IntToStr(AVersion) + '"';
end;

function IsBlank(C: Char): Boolean;
begin
  Result := (C = ' ') or (C = #9);
end;

// etagc: %x21 / %x23-7E / obs-text (%x80-FF; any non-ASCII character here).
function IsETagChar(C: Char): Boolean;
begin
  Result := (C = #$21) or ((C >= #$23) and (C <= #$7E)) or (Ord(C) >= $80);
end;

function EvaluateIfMatch(const AHeader, ACurrentETag: string): TIfMatchResult;
var
  P, N, LStart: Integer;
  LWeak, LMatched, LAny: Boolean;
begin
  N := Length(AHeader);
  P := 1;
  while (P <= N) and IsBlank(AHeader[P]) do
    Inc(P);
  if P > N then
    Exit(imAbsent);
  if Trim(AHeader) = '*' then
    Exit(imAny);
  LMatched := False;
  LAny := False;
  // #entity-tag: elements separated by commas, blanks around them, empty
  // elements allowed (RFC 9110, section 5.6.1).
  while P <= N do
  begin
    while (P <= N) and (IsBlank(AHeader[P]) or (AHeader[P] = ',')) do
      Inc(P);
    if P > N then
      Break;
    LWeak := False;
    if (P + 1 <= N) and (AHeader[P] = 'W') and (AHeader[P + 1] = '/') then
    begin
      LWeak := True;
      Inc(P, 2);
    end;
    if (P > N) or (AHeader[P] <> '"') then
      Exit(imInvalid);
    LStart := P;
    Inc(P);
    while (P <= N) and IsETagChar(AHeader[P]) do
      Inc(P);
    if (P > N) or (AHeader[P] <> '"') then
      Exit(imInvalid);
    Inc(P);
    LAny := True;
    if not LWeak and (ACurrentETag <> '') and
      (Copy(AHeader, LStart, P - LStart) = ACurrentETag) then
      LMatched := True;
    while (P <= N) and IsBlank(AHeader[P]) do
      Inc(P);
    if (P <= N) and (AHeader[P] <> ',') then
      Exit(imInvalid);
  end;
  if not LAny then
    Exit(imInvalid); // only commas
  if LMatched then
    Result := imMatch
  else
    Result := imNoMatch;
end;

procedure RequireIfMatchSent(const AHeader: string; AAcceptAny: Boolean);
begin
  case EvaluateIfMatch(AHeader, '') of
    imAbsent:
      raise EHttpException.Create(428, 'If-Match is required: send the ETag of the version ' +
        'you read.', CODE_PRECONDITION_REQUIRED);
    imAny:
      if not AAcceptAny then
        raise EHttpException.Create(428, 'If-Match must name the version you read (its ETag); ' +
          '"*" is not accepted here.', CODE_PRECONDITION_REQUIRED);
    imInvalid:
      raise EHttpException.Create(400, 'If-Match must be one or more entity tags, such as "3".',
        CODE_INVALID_IF_MATCH);
  end;
end;

procedure RequireIfMatch(const AHeader, ACurrentETag: string; AAcceptAny: Boolean);
begin
  RequireIfMatchSent(AHeader, AAcceptAny);
  case EvaluateIfMatch(AHeader, ACurrentETag) of
    imMatch, imAny:
      ;
  else
    raise EHttpException.Create(412, 'The resource changed since you read it: read it again ' +
      '(its ETag is now ' + ACurrentETag + ').', CODE_PRECONDITION_FAILED);
  end;
end;

procedure RaisePreconditionFailed;
begin
  raise EHttpException.Create(412, 'The resource changed since you read it: read it again.',
    CODE_PRECONDITION_FAILED);
end;

end.
