defmodule Assistant.Embeddings.Serving do
  @moduledoc false

  def child_spec(_opts) do
    model_repo = {:hf, "thenlper/gte-small"}
    {:ok, model_info} = Bumblebee.load_model(model_repo)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(model_repo)

    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
        output_pool: :mean_pooling,
        output_attribute: :hidden_state,
        embedding_processor: :l2_norm,
        compile: [batch_size: 32, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    {Nx.Serving, serving: serving, name: Assistant.Embeddings, batch_size: 32, batch_timeout: 100}
  end
end
