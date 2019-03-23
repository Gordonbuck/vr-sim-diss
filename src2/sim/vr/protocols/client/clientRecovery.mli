val begin_clientrecovery : VR_State.client_state -> (VR_State.client_state * VR_State.protocol_event list)
val on_clientrecovery : VR_State.client_state -> VR_State.index -> (VR_State.client_state * VR_State.protocol_event list)
val on_clientrecoveryresponse : VR_State.client_state -> VR_State.index -> VR_State.index -> VR_State.index -> (VR_State.client_state * VR_State.protocol_event list)