-- Loops can use any signed integral type

let main (x: i8): i64 =
  let x = loop (x =     x) for i < 0x80i8  do x + i
  let x = loop (x = i16 x) for i < 0x80i16 do x + i
  let x = loop (x = i32 x) for i < 0x80i32 do x + i
  let x = loop (x = i64 x) for i < 0x80i64 do x + i
  in x
