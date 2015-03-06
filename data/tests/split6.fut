// Split a row of an array.
//
// Now we are thinking with portals (and the code generator messed
// this up at one point).
//
// The reason I return the sums and not the arrays is that the code
// generator gets of too easy if it can just directly
// allocate/manifest the arrays for the function return.  This way is
// more likely to trigger bugs.
fun {int,int} main(int n, int i, [[int]] a) =
  let {a,b} = split( (n), a[i]) in
  {reduce(op+, 0, a), reduce(op+, 0, b)}
