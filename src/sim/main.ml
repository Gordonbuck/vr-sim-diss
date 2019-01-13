open Core
open Simulator
open Protocol
open Parameters

let main () =
  let module VR_Sim = Make(VR)(VR_test_params) in
  VR_Sim.run ()

let () = main ()
