val begin_clientrecovery : VR_State.client_state -> (VR_State.client_state * VR_State.protocol_event list * VR_State.trace)
val on_clientrecovery : VR_State.replica_state -> VR_State.index -> (VR_State.replica_state * VR_State.protocol_event list * VR_State.trace)
val on_clientrecoveryresponse : VR_State.client_state -> VR_State.index -> VR_State.index -> VR_State.index -> (VR_State.client_state * VR_State.protocol_event list * VR_State.trace)