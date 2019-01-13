module StateMachine = StateMachine.KeyValueStore

type client_message =
  | Reply of int * int * StateMachine.result
  | ClientRecoveryResponse of int * int * int

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

type client_timeout = 
  | RequestTimeout of int
  | ClientRecoveryTimeout of int

type replica_timeout = 
  | HeartbeatTimeout of int * int
  | PrepareTimeout of int * int
  | PrimaryTimeout of int * int
  | StateTransferTimeout of int * int
  | StartViewChangeTimeout of int
  | DoViewChangeTimeout of int
  | RecoveryTimeout of int
  | GetStateTimeout of int * int

type message = ReplicaMessage of replica_message | ClientMessage of client_message

type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list

type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int

type protocol_event = Communication of communication | Timeout of timeout
