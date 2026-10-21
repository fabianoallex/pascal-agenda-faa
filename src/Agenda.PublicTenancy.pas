unit Agenda.PublicTenancy;

{$I agenda.inc}

{ The tenant of a public route, from its path: /public/<slug>/... names the
  tenant whose id is <slug> (docs/design.md, M3). The decisions only, with no
  HTTP: the program's middleware calls ResolvePathTenant and marks the
  request as pascal-api-infra-faa's TTenantMiddleware does, so everything
  after it (repositories, the access log's tenant.id) works as on the
  authenticated routes.

  - One answer for every tenant that can't be used: a slug that can't be an
    id, one the catalog doesn't have and a suspended one are all False, which
    the program answers 404 with one body. Anyone can try names on a public
    route, so a different answer would list who the customers are (M3
    decision 3, a refinement of the library's multi-tenancy decision 7 for
    sources nobody authenticated).
  - Text that can't be a tenant id (the catalog's rule: 1 to 40 of a-z, 0-9
    and "-") never reaches the catalog.
  - The prefix matches whole segments: /publicity/... is not under /public.

  A library candidate (docs/design.md: "Tenant from the path or host", in
  pascal-api-infra-faa's PascalApi.Tenancy), written under the libraries'
  rules so it can move as it is. }

interface

uses
  PascalApi.Tenancy;

const
  /// The public routes' prefix, with its slashes.
  PUBLIC_PATH_PREFIX = '/public/';

/// True when APath is APrefix's segment or under it ('/public', '/public/',
/// '/public/x'); APrefix ends with '/'. Case-sensitive, as the routes are.
function IsUnderPathPrefix(const APath, APrefix: string): Boolean;

/// The segment right after APrefix ('/public/acme/services' -> 'acme').
/// False when APath isn't under APrefix or the segment can't be a tenant id.
function TryPathTenant(const APath, APrefix: string; out ASlug: string): Boolean;

/// The usable tenant a path names: True and AInfo only for one the catalog
/// has and isn't suspended; False for anything else, whatever the reason.
function ResolvePathTenant(const ACatalog: ITenantCatalog; const APath, APrefix: string;
  out AInfo: TTenantInfo): Boolean;

implementation

uses
  SysUtils;

const
  MAX_TENANT_ID_CHARS = 40;

function CanBeTenantId(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := (AText <> '') and (Length(AText) <= MAX_TENANT_ID_CHARS);
  if not Result then
    Exit;
  for I := 1 to Length(AText) do
    if not CharInSet(AText[I], ['a'..'z', '0'..'9', '-']) then
      Exit(False);
end;

function IsUnderPathPrefix(const APath, APrefix: string): Boolean;
begin
  // '/public' itself, or anything that starts with '/public/'.
  Result := (APrefix <> '') and ((Copy(APath, 1, Length(APrefix)) = APrefix) or
    (APath = Copy(APrefix, 1, Length(APrefix) - 1)));
end;

function TryPathTenant(const APath, APrefix: string; out ASlug: string): Boolean;
var
  LRest: string;
  LSlash: Integer;
begin
  ASlug := '';
  if (APrefix = '') or (Copy(APath, 1, Length(APrefix)) <> APrefix) then
    Exit(False);
  LRest := Copy(APath, Length(APrefix) + 1, MaxInt);
  LSlash := Pos('/', LRest);
  if LSlash > 0 then
    LRest := Copy(LRest, 1, LSlash - 1);
  Result := CanBeTenantId(LRest);
  if Result then
    ASlug := LRest;
end;

function ResolvePathTenant(const ACatalog: ITenantCatalog; const APath, APrefix: string;
  out AInfo: TTenantInfo): Boolean;
var
  LSlug: string;
begin
  AInfo := Default(TTenantInfo);
  Result := (ACatalog <> nil) and TryPathTenant(APath, APrefix, LSlug) and
    (CheckTenant(ACatalog, LSlug, AInfo) = tcOk);
  if not Result then
    AInfo := Default(TTenantInfo);
end;

end.
