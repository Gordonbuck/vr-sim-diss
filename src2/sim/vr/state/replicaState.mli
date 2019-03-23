module ReplicaState (StateMachine : StateMachine.StateMachine_type) : sig 

  type status =
    | Normal
    | ViewChange
    | Recovering

  type replica_state = {
    configuration : int list;
    replica_no : int;
    view_no : int;
    status: status;
    op_no : int;
    log: (StateMachine.operation * int * int) list;
    commit_no : int;
    client_table: (int * StateMachine.result option) list;
    queued_prepares : (StateMachine.operation * int * int) option list;
    waiting_prepareoks : int list;
    casted_prepareoks : int list;
    highest_seen_commit_no : int;
    no_startviewchanges : int;
    received_startviewchanges : bool list;
    doviewchanges : (int * (StateMachine.operation * int * int) list * int * int * int * int) list;
    last_normal_view_no : int;
    recovery_nonce : int; 
    no_recoveryresponses : int;
    received_recoveryresponses : bool list;
    primary_recoveryresponse : (int * int * (StateMachine.operation * int * int) list * int * int * int) option;
    valid_timeout : int;
    no_primary_comms : int;
    mach : StateMachine.t;
  }

  type replica_message =
    | Request of StateMachine.operation * int * int
    | Prepare of int * (StateMachine.operation * int * int) * int * int
    | PrepareOk of int * int * int
    | Commit of int * int
    | StartViewChange of int * int
    | DoViewChange of int * (StateMachine.operation * int * int) list * int * int * int * int
    | StartView of int * (StateMachine.operation * int * int) list * int * int
    | Recovery of int * int
    | RecoveryResponse of int * int * ((StateMachine.operation * int * int) list * int * int) option * int
    | ClientRecovery of int
    | GetState of int * int * int
    | NewState of int * (StateMachine.operation * int * int) list * int * int

  type replica_timeout = 
    | HeartbeatTimeout of int * int
    | PrepareTimeout of int * int
    | PrimaryTimeout of int * int
    | StateTransferTimeout of int * int
    | StartViewChangeTimeout of int
    | DoViewChangeTimeout of int
    | RecoveryTimeout of int
    | GetStateTimeout of int * int

end
