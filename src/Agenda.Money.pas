unit Agenda.Money;

{$I agenda.inc}

{ Prices: Currency in the API (exact in JSON since pascal-jsonmapper-faa
  0.6.0), whole cents in the database (PRICE_CENTS BIGINT: exact on every
  database; SQLite would keep a NUMERIC as a REAL).

  The conversion works on Currency's own representation, an Int64 scaled by
  10,000 on both compilers, through an absolute variable: no floating point
  on the way (pascal-db-faa's gotcha 18: a Double typecast of a Currency
  converts on FPC for Windows and not on FPC for Linux). }

interface

/// False when APrice has a fraction of a cent (12.345).
function TryCurrencyToCents(APrice: Currency; out ACents: Int64): Boolean;

function CentsToCurrency(ACents: Int64): Currency;

implementation

function TryCurrencyToCents(APrice: Currency; out ACents: Int64): Boolean;
var
  LPrice: Currency;
  LScaled: Int64 absolute LPrice;
begin
  LPrice := APrice;
  Result := LScaled mod 100 = 0;
  if Result then
    ACents := LScaled div 100
  else
    ACents := 0;
end;

function CentsToCurrency(ACents: Int64): Currency;
var
  LPrice: Currency;
  LScaled: Int64 absolute LPrice;
begin
  LScaled := ACents * 100;
  Result := LPrice;
end;

end.
