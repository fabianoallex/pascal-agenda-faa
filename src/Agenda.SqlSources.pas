unit Agenda.SqlSources;

{$I agenda.inc}

{ A SQL source that falls back to a common directory: <ADirectory>/<AName>
  first, then <the common directory>/<AName> when the first isn't there.

  pascal-db-faa's loader asks for <SQLDirectory>/<KEY>, one directory per
  database ('PG', 'SQLITE'), with no fallback, so an application whose SQL
  is the same on two databases keeps two copies of every statement or sets
  one directory for both and loses the place for a statement that has to
  differ. With this source, the common directory holds what both run and
  each database's directory only what is its own: a key in 'PG' overrides
  the common one for PostgreSQL and nothing else.

  Written under pascal-db-faa's rules, a candidate for its
  PascalDb.SqlSources (docs/design.md, "Library candidates"): it wraps any
  ISqlSource (memory, directory, resources, composite), so the lookup rule
  is the only thing it adds. The not-found message names both places
  ("memory PG/X, then memory COMMON/X"). Asked for the common directory
  itself, it looks once. Directory names compare without case, as the
  directory source does on Linux. }

interface

uses
  PascalDb.SqlSources;

type
  TFallbackSqlSource = class(TInterfacedObject, ISqlSource)
  private
    FInner: ISqlSource;
    FFallbackDirectory: string;
    function IsFallback(const ADirectory: string): Boolean;
  public
    /// AInner answers both lookups; AFallbackDirectory is the common one.
    constructor Create(const AInner: ISqlSource; const AFallbackDirectory: string);
    function TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
    function Describe(const ADirectory, AName: string): string;
    property FallbackDirectory: string read FFallbackDirectory;
  end;

implementation

uses
  SysUtils;

constructor TFallbackSqlSource.Create(const AInner: ISqlSource; const AFallbackDirectory: string);
begin
  inherited Create;
  if AInner = nil then
    raise EArgumentException.Create('TFallbackSqlSource: AInner is nil');
  if AFallbackDirectory = '' then
    raise EArgumentException.Create('TFallbackSqlSource: AFallbackDirectory is empty');
  FInner := AInner;
  FFallbackDirectory := AFallbackDirectory;
end;

function TFallbackSqlSource.IsFallback(const ADirectory: string): Boolean;
begin
  Result := SameText(ADirectory, FFallbackDirectory);
end;

function TFallbackSqlSource.TryGetSql(const ADirectory, AName: string; out ASql: string): Boolean;
begin
  Result := FInner.TryGetSql(ADirectory, AName, ASql);
  if not Result and not IsFallback(ADirectory) then
    Result := FInner.TryGetSql(FFallbackDirectory, AName, ASql);
end;

function TFallbackSqlSource.Describe(const ADirectory, AName: string): string;
begin
  Result := FInner.Describe(ADirectory, AName);
  if not IsFallback(ADirectory) then
    Result := Result + ', then ' + FInner.Describe(FFallbackDirectory, AName);
end;

end.
