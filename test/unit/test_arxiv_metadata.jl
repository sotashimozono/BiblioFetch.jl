using BiblioFetch
using Test

# Minimal but realistic arXiv Atom response — one entry per feed, which is what
# `arxiv_metadata(id)` requests via `id_list=<id>`.
const _ARXIV_BASIC = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/1706.03762v7</id>
    <updated>2023-08-02T00:41:18Z</updated>
    <published>2017-06-12T17:57:34Z</published>
    <title>Attention Is All You Need</title>
    <summary>We propose a new simple network architecture...</summary>
    <author><name>Ashish Vaswani</name></author>
    <author><name>Noam Shazeer</name></author>
    <author><name>Niki Parmar</name></author>
    <arxiv:doi xmlns:arxiv="http://arxiv.org/schemas/atom">10.48550/arXiv.1706.03762</arxiv:doi>
    <arxiv:primary_category xmlns:arxiv="http://arxiv.org/schemas/atom" term="cs.CL" scheme="http://arxiv.org/schemas/atom"/>
  </entry>
</feed>
"""

const _ARXIV_WITH_JOURNAL = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/0608208v1</id>
    <published>2006-08-09T00:00:00Z</published>
    <title>Anyons in an exactly solved model and beyond</title>
    <author><name>Alexei Kitaev</name></author>
    <arxiv:doi xmlns:arxiv="http://arxiv.org/schemas/atom">10.1016/j.aop.2005.10.005</arxiv:doi>
    <arxiv:journal_ref xmlns:arxiv="http://arxiv.org/schemas/atom">Annals Phys. 321 (2006) 2-111</arxiv:journal_ref>
    <arxiv:primary_category xmlns:arxiv="http://arxiv.org/schemas/atom" term="cond-mat.mes-hall"/>
  </entry>
</feed>
"""

const _ARXIV_MULTILINE_TITLE = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/1234.5678v1</id>
    <published>2020-01-15T00:00:00Z</published>
    <title>A very long title
      that spans two lines   and has   extra spaces</title>
    <author><name>First Author</name></author>
  </entry>
</feed>
"""

const _ARXIV_HTML_ENTITIES = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/9999.0000v1</id>
    <published>2022-05-01T00:00:00Z</published>
    <title>Black &amp; Scholes &lt; everyone else</title>
    <author><name>A. &quot;Quoted&quot; Author</name></author>
  </entry>
</feed>
"""

const _ARXIV_EMPTY = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
</feed>
"""

@testset "parse arxiv Atom: basic entry" begin
    m = BiblioFetch._parse_arxiv_atom(_ARXIV_BASIC)
    @test m !== nothing
    @test m.title == "Attention Is All You Need"
    @test m.authors == ["Ashish Vaswani", "Noam Shazeer", "Niki Parmar"]
    @test m.year == 2017
    @test m.journal === nothing
    @test m.doi == "10.48550/arXiv.1706.03762"
    @test m.primary_category == "cs.CL"
end

@testset "parse arxiv Atom: published paper with journal_ref" begin
    m = BiblioFetch._parse_arxiv_atom(_ARXIV_WITH_JOURNAL)
    @test m.title == "Anyons in an exactly solved model and beyond"
    @test m.authors == ["Alexei Kitaev"]
    @test m.year == 2006       # from journal_ref "(2006)", NOT from <published>
    @test m.journal == "Annals Phys. 321 (2006) 2-111"
    @test m.doi == "10.1016/j.aop.2005.10.005"
end

@testset "parse arxiv Atom: multiline title collapses whitespace" begin
    m = BiblioFetch._parse_arxiv_atom(_ARXIV_MULTILINE_TITLE)
    @test m.title == "A very long title that spans two lines and has extra spaces"
end

@testset "parse arxiv Atom: HTML entity decoding" begin
    m = BiblioFetch._parse_arxiv_atom(_ARXIV_HTML_ENTITIES)
    @test m.title == "Black & Scholes < everyone else"
    @test m.authors == ["A. \"Quoted\" Author"]
end

const _ARXIV_WITH_AFFILIATION = """
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>http://arxiv.org/abs/0000.0000v1</id>
    <published>2018-03-01T00:00:00Z</published>
    <title>Paper with affiliations</title>
    <author>
      <name>First Author</name>
      <arxiv:affiliation xmlns:arxiv="http://arxiv.org/schemas/atom">Univ. A</arxiv:affiliation>
    </author>
    <author>
      <name>Second Author</name>
      <arxiv:affiliation xmlns:arxiv="http://arxiv.org/schemas/atom">Lab B</arxiv:affiliation>
    </author>
  </entry>
</feed>
"""

@testset "parse arxiv Atom: authors with affiliations" begin
    m = BiblioFetch._parse_arxiv_atom(_ARXIV_WITH_AFFILIATION)
    @test m.authors == ["First Author", "Second Author"]
end

@testset "parse arxiv Atom: empty feed returns nothing" begin
    @test BiblioFetch._parse_arxiv_atom(_ARXIV_EMPTY) === nothing
    @test BiblioFetch._parse_arxiv_atom("") === nothing
    @test BiblioFetch._parse_arxiv_atom("garbage not xml") === nothing
end
