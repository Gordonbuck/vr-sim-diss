val on_request : replica_state -> int -> int -> int -> (replica_state * VR_State.protocol_event list)
val on_prepare : replica_state -> int -> (int * int * int) -> int -> int -> (replica_state * VR_State.protocol_event list)
val on_prepareok : replica_state -> int -> int -> int -> (replica_state * VR_State.protocol_event list)
val on_commit : replica_state -> int -> int -> (replica_state * VR_State.protocol_event list)