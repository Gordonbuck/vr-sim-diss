open Core

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

type message = ReplicaMessage of replica_message | ClientMessage of client_message

type communication = Unicast of message * int |  Broadcast of message | MultiComm of communication list
