(* FPC only: AgendaApi.dpr includes it inside {$IFDEF FPC}. Delphi evaluates
  a {$IF} expression even in an inactive {$IFDEF FPC} block, and stops at
  FPC_FULLVERSION (E2026); a file it never opens keeps the test away from it. *)

// FPC 3.2.2's server closes the connection after every response without
// saying so; keep-alive arrives in 3.3.1 (ConnectionClose in AgendaApi.dpr).
{$IF FPC_FULLVERSION < 30301}
  {$DEFINE AGENDA_CONNECTION_CLOSE}
{$ENDIF}
