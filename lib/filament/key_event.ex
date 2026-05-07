defmodule Filament.KeyEvent do
  @moduledoc false
  defstruct [:key, ctrl: false, shift: false, alt: false, meta: false]
end
