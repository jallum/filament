# Used by "mix format"
[
  plugins: [Styler],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "examples/*/lib/**/*.{ex,exs}",
    "examples/*/test/**/*.{ex,exs}",
    "examples/*/config/**/*.{ex,exs}"
  ],
  line_length: 120
]
