open Simulator

let main () =
  let module VR_Sim = Simulator(VR)(VR_Params) in
  VR_Sim.run ()

let () = main ()