# Generates heroicons.css from SVG files in deps/heroicons/optimized.
# Maps hero-* class names to mask-image SVG data URIs.
#
# Usage: mix run priv/scripts/generate_heroicons_css.exs

deps_path = "deps/heroicons/optimized"

variants = %{
  "" => "24/outline",
  "-solid" => "24/solid",
  "-mini" => "20/solid",
  "-micro" => "16/solid"
}

sizes = %{
  "" => "1.5rem",
  "-solid" => "1.5rem",
  "-mini" => "1.25rem",
  "-micro" => "1rem"
}

# Collect all hero-* names from the codebase
{output, _} =
  System.cmd("grep", [
    "-roh",
    "\"hero-[a-z][-a-z0-9]*\"",
    "lib/assistant_web/",
    "deps/petal_components/lib/"
  ])

names =
  output
  |> String.split("\n", trim: true)
  |> Enum.map(&String.trim(&1, "\""))
  |> Enum.uniq()
  |> Enum.sort()

url_encode_svg = fn svg ->
  svg
  |> String.trim()
  |> String.replace("\n", " ")
  |> String.replace(~r/\s+/, " ")
  |> String.replace("\"", "'")
  |> String.replace("#", "%23")
  |> String.replace("<", "%3C")
  |> String.replace(">", "%3E")
  |> then(&"url(\"data:image/svg+xml,#{&1}\")")
end

header = """
/* Heroicons CSS — auto-generated from deps/heroicons/optimized SVGs.
   Maps hero-* class names to mask-image SVG data URIs.
   Regenerate with: mix run priv/scripts/generate_heroicons_css.exs */

"""

css_rules =
  Enum.map(names, fn name ->
    {suffix, base_name} =
      cond do
        String.ends_with?(name, "-solid") ->
          {"-solid", name |> String.trim_leading("hero-") |> String.trim_trailing("-solid")}

        String.ends_with?(name, "-mini") ->
          {"-mini", name |> String.trim_leading("hero-") |> String.trim_trailing("-mini")}

        String.ends_with?(name, "-micro") ->
          {"-micro", name |> String.trim_leading("hero-") |> String.trim_trailing("-micro")}

        true ->
          {"", String.trim_leading(name, "hero-")}
      end

    dir = variants[suffix]
    size = sizes[suffix]
    svg_path = Path.join([deps_path, dir, "#{base_name}.svg"])

    if File.exists?(svg_path) do
      svg = File.read!(svg_path)
      encoded = url_encode_svg.(svg)

      """
      .#{name} {
        -webkit-mask-image: #{encoded};
        mask-image: #{encoded};
        -webkit-mask-repeat: no-repeat;
        mask-repeat: no-repeat;
        mask-size: 100%;
        -webkit-mask-size: 100%;
        background-color: currentColor;
        vertical-align: middle;
        display: inline-block;
        width: #{size};
        height: #{size};
      }
      """
    else
      IO.puts(:stderr, "WARNING: SVG not found for #{name} at #{svg_path}")
      ""
    end
  end)
  |> Enum.join("\n")

all_css = header <> css_rules
File.write!("assets/css/heroicons.css", all_css)
IO.puts("Generated assets/css/heroicons.css with #{length(names)} icons (#{byte_size(all_css)} bytes)")
