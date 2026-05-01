defmodule Test.Analysis do
  import Phoenix.Component
  
  def sample_keyed_for do
    assigns = %{items: [%{id: 1, text: "Item 1"}]}
    
    ~H"""
    <ul>
      <li :for={item <- @items} key={item.id}>
        {@item.text}
      </li>
    </ul>
    """
  end
  
  def sample_nokey_for do
    assigns = %{items: [%{id: 1, text: "Item 1"}]}
    
    ~H"""
    <ul>
      <li :for={item <- @items}>
        {@item.text}
      </li>
    </ul>
    """
  end
end

IO.puts("AST Analysis: Modules compiled successfully")
