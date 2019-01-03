open Core

module StateMachine = StateMachine.KeyValueStore

type status =
  | Normal
  | ViewChange
  | Recovering

type client_state = {
  (* protocol state *)
  configuration : int list;
  view_no : int;
  client_id : int;
  request_no : int;

  (* index of next operation to be sent in request*)
  next_op_index : int;
  (* list of operations client wants to perform *)
  operations_to_do : StateMachine.operation list;

  (* indicates if the client is recovering from a crash or not *)
  recovering : bool;
  (* the number of clientrecoverresponses received for current recovery *)
  no_clientrecoveryresponses : int;
  (* for each replica indicates whether they have responded to recovery or not *)
  received_clientrecoveryresponses : bool list;

  (* increment on replies and recovery *)
  valid_timeout : int;
}

type replica_state = {
  (* protocol state *)
  configuration : int list;
  replica_no : int;
  view_no : int;
  status: status;
  op_no : int;
  log: (StateMachine.operation * int * int) list;
  commit_no : int;
  client_table: (int * StateMachine.result option) list;

  (* list of operations depending on previous operations not yet seen *)
  queued_prepares : (StateMachine.operation * int * int) option list;
  (* for each not yet committed operation, the number of prepareoks received *)
  waiting_prepareoks : int list;
  (* for each replica, the highest op_no seen in a prepareok message *)
  casted_prepareoks : int list;
  (* the higest commit_no seen in a prepare/commit message *)
  highest_seen_commit_no : int;

  (* number of startviewchange messages received from different replicas *)
  no_startviewchanges : int;
  (* for each replica, indicates whether this has received a startviewchange from them *)
  received_startviewchanges : bool list;
  (* list of doviewchange messages received *)
  doviewchanges : (int * (StateMachine.operation * int * int) list * int * int * int * int) list;
  (* view_no of the last view for which status was normal *)
  last_normal_view_no : int;

  (* the nonce used in this replica's most recent recovery *)
  recovery_nonce : int; 
  (* number of recoveryresponse messages received from different replicas *)
  no_recoveryresponses : int;
  (* for each replica, indicates whether this has received a recoveryresponse from them *)
  received_recoveryresponses : bool list;
  (* recoveryresponse message from primary of latest view seen in recoveryresponse messages *)
  primary_recoveryresponse : (int * int * (StateMachine.operation * int * int) list * int * int * int) option;

  (* increment on recovery and view change *)
  valid_timeout : int;
  (* if primary: no. communications sent, else: no. communications received from primary*)
  no_primary_comms : int;

  (* replicated state machine *)
  mach : StateMachine.t;
}
