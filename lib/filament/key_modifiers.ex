defmodule Filament.KeyModifiers do
  @moduledoc """
  The modifier keys held during a key press, passed to an `on_key` handler
  as its second argument:

      on_key={fn
        "k", %Filament.KeyModifiers{ctrl: true} -> open_palette.()
        _, _ -> :ignore
      end}
  """
  defstruct ctrl: false, shift: false, alt: false, meta: false

  @type t :: %__MODULE__{ctrl: boolean(), shift: boolean(), alt: boolean(), meta: boolean()}
end
