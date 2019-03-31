val start_replica : VR_State.replica_state -> (VR_State.replica_state * VR_State.protocol_event list * VR_State.trace)
val on_request : VR_State.replica_state -> VR_State.StateMachine.operation -> VR_State.index -> VR_State.index -> (VR_State.replica_state * VR_State.protocol_event list * VR_State.trace)
val on_prepare : VR_State.replica_state -> VR_State.index -> (VR_State.StateMachine.operation * VR_State.index * VR_State.index) -> VR_State.index -> VR_State.index -> (VR_State.replica_state * VR_State.protocol_event list * VR_State.trace)
val on_prepareok : VR_State.replica_state -> VR_State.index -> VR_State.index -> VR_State.index -> (VR_State.replica_state * VR_State.protocol_event list * VR_State.trace)
val on_commit : VR_State.replica_state -> VR_State.index -> VR_State.index -> (VR_State.replica_state * VR_State.protocol_event list * VR_State.trace)