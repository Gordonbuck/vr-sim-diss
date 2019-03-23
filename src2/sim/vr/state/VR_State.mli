module StateMachine = StateMachine.KeyValueStore

open ReplicaState.ReplicaState(StateMachine)
open ClientState.ClientState(StateMachine)

type message = ReplicaMessage of replica_message | ClientMessage of client_message

type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list

type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int

type protocol_event = Communication of communication | Timeout of timeout
