open Core

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

type timeout = ReplicaTimeout of int * replica_timeout | ClientTimeout of int * client_timeout
