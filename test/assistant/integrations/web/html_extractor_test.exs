defmodule Assistant.Integrations.Web.HtmlExtractorTest do
  use ExUnit.Case, async: true
  @moduletag :external

  alias Assistant.Integrations.Web.HtmlExtractor

  test "extracts title, canonical url, and readable text" do
    html = """
    <html>
      <head>
        <title>Example title</title>
        <link rel="canonical" href="https://example.com/canonical" />
      </head>
      <body>
        <main>
          <h1>Hello</h1>
          <p>World</p>
        </main>
      </body>
    </html>
    """

    assert {:ok, extracted} = HtmlExtractor.extract(html)
    assert extracted.title == "Example title"
    assert extracted.canonical_url == "https://example.com/canonical"
    assert extracted.content =~ "Hello"
    assert extracted.content =~ "World"
  end
end
