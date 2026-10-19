unit Agenda.Flags;

{$I agenda.inc}

{ A flag (true/false in the API) as the INTEGER column that stores it (1/0):
  the same type on SQLite and PostgreSQL, bound as an Integer.

  Why not IParams.Booleans/OptBooleans: on PostgreSQL a Boolean parameter
  goes out typed as boolean, and the server refuses it for an INTEGER column
  ("column "active" is of type integer but expression is of type boolean";
  measured with SQLdb on FPC, 2026-10-19). SQLite takes either. Reading is
  fine on both: IQueryResult.Booleans reads an INTEGER 1 as True.

  OptFlag keeps the optional's state, so a partial UPDATE binds it next to
  its ProcessTag with no if: absent stays absent (nothing bound), a value
  becomes 1 or 0. It is a cross-type Map, which pascal-common-faa's
  optionals don't have (Map keeps the type): a library candidate,
  docs/design.md. }

interface

uses
  PascalCommon.Optionals;

/// 1 for True, 0 for False.
function FlagOf(AValue: Boolean): Integer;

/// Absent stays absent; a value becomes FlagOf(value).
function OptFlag(const AValue: IOptBoolean): IOptInteger;

implementation

function FlagOf(AValue: Boolean): Integer;
begin
  Result := Ord(AValue);
end;

function OptFlag(const AValue: IOptBoolean): IOptInteger;
begin
  if AValue.HasValue then
    Result := TOptNullInteger.From(FlagOf(AValue.Value))
  else
    Result := TOptNullInteger.Undefined;
end;

end.
