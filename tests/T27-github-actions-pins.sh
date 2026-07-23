#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_dir="$repo_root/.github/workflows"

ruby - "$workflow_dir" <<'RUBY'
require "pathname"
require "psych"

workflow_dir = Pathname.new(ARGV.fetch(0))
immutable_remote =
  %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?@[0-9a-f]{40}\z}
immutable_container = %r{\Adocker://[^@\s]+@sha256:[0-9a-f]{64}\z}
version_comment = /\A#\s*v\d+(?:\.\d+){0,2}(?:[-+][0-9A-Za-z.-]+)?\s*\z/
snapshot_comment = %r{\A#\s*[A-Za-z0-9._/-]+\s+@\s+\d{4}-\d{2}-\d{2}\s*\z}

action_parent = lambda do |path|
  (path.length == 2 && path[0] == "jobs") ||
    (path.length == 4 && path[0] == "jobs" && path[2] == "steps")
end

readable_comment = lambda do |line, target|
  target_index = line.index(target)
  next false unless target_index

  comment_index = line.index("#", target_index + target.length)
  next false unless comment_index

  comment = line[comment_index..-1].strip
  version_comment.match?(comment) || snapshot_comment.match?(comment)
end

validate_reference = lambda do |path, node, lines, failures|
  line_number = node.start_line + 1
  location = "#{path}:#{line_number}"
  target = node.value
  next if target.start_with?("./")

  if target.start_with?("docker://")
    unless immutable_container.match?(target)
      failures << "#{location}: container action is not pinned to a sha256 digest: #{target}"
    end
  elsif !immutable_remote.match?(target)
    failures << "#{location}: remote action is not pinned to a full commit SHA: #{target}"
  end

  unless readable_comment.call(lines.fetch(node.start_line, ""), target)
    failures << "#{location}: pinned action lacks a readable version/snapshot comment"
  end
end

walk = nil
walk = lambda do |node, path, source_path, lines, failures|
  case node
  when Psych::Nodes::Mapping
    node.children.each_slice(2) do |key, value|
      key_name = key.is_a?(Psych::Nodes::Scalar) ? key.value : nil
      if key_name == "<<"
        failures << "#{source_path}:#{key.start_line + 1}: YAML merge keys are not allowed"
      end

      if key_name == "uses" && action_parent.call(path)
        if value.is_a?(Psych::Nodes::Scalar)
          validate_reference.call(source_path, value, lines, failures)
        else
          failures << "#{source_path}:#{value.start_line + 1}: uses must be a literal scalar"
        end
      end

      walk.call(value, path + [key_name], source_path, lines, failures)
    end
  when Psych::Nodes::Sequence
    node.children.each_with_index do |child, index|
      walk.call(child, path + [index], source_path, lines, failures)
    end
  when Psych::Nodes::Alias
    failures << "#{source_path}:#{node.start_line + 1}: YAML aliases are not allowed"
  else
    Array(node.children).each do |child|
      walk.call(child, path, source_path, lines, failures)
    end
  end
end

validate = lambda do |path, text|
  failures = []
  stream = Psych.parse_stream(text)
  walk.call(stream, [], path, text.lines, failures)
  failures
rescue Psych::SyntaxError => error
  ["#{path}: invalid YAML: #{error.message}"]
end

workflows = (workflow_dir.glob("*.yml") + workflow_dir.glob("*.yaml")).sort
abort "no GitHub Actions workflows found" if workflows.empty?

failures = workflows.flat_map { |workflow| validate.call(workflow, workflow.read) }
fixture_prefix = <<~YAML
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
YAML

floating_spellings = [
  "        - uses: actions/checkout@v4 # v4\n",
  "        - \"uses\": actions/checkout@v4 # v4\n",
  "        -    uses : actions/checkout@v4 # v4\n",
]
floating_spellings.each_with_index do |spelling, index|
  fixture_failures = validate.call(
    Pathname.new("floating-action-fixture-#{index}.yml"),
    fixture_prefix + spelling,
  )
  unless fixture_failures.any? { |failure| failure.include?("not pinned to a full commit SHA") }
    failures << "negative fixture #{index} unexpectedly accepted a floating action tag"
  end
end

flow_fixture = <<~YAML
  jobs: {test: {runs-on: ubuntu-latest, steps: [{uses: actions/checkout@v4}]}} # v4
YAML
flow_failures = validate.call(Pathname.new("flow-fixture.yml"), flow_fixture)
unless flow_failures.any? { |failure| failure.include?("not pinned to a full commit SHA") }
  failures << "flow-mapping fixture unexpectedly accepted a floating action tag"
end

reusable_workflow_fixture = <<~YAML
  jobs:
    delegated:
      uses: example/reusable/.github/workflows/check.yml@main # main
YAML
reusable_failures = validate.call(
  Pathname.new("reusable-workflow-fixture.yml"),
  reusable_workflow_fixture,
)
unless reusable_failures.any? { |failure| failure.include?("not pinned to a full commit SHA") }
  failures << "job-level fixture unexpectedly accepted a floating reusable workflow"
end

container_failures = validate.call(
  Pathname.new("floating-container-fixture.yml"),
  fixture_prefix + "        - uses: docker://alpine:3.22 # v3.22\n",
)
unless container_failures.any? { |failure| failure.include?("not pinned to a sha256 digest") }
  failures << "negative fixture unexpectedly accepted a floating container tag"
end

comment_failures = validate.call(
  Pathname.new("comment-fixture.yml"),
  fixture_prefix +
    "        - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # x\n",
)
unless comment_failures.any? { |failure| failure.include?("lacks a readable") }
  failures << "negative fixture unexpectedly accepted an unreadable pin comment"
end

alias_fixture = <<~YAML
  hidden: &floating
    uses: actions/checkout@v4
  jobs:
    test:
      runs-on: ubuntu-latest
      steps:
        - <<: *floating
YAML
alias_failures = validate.call(Pathname.new("alias-fixture.yml"), alias_fixture)
unless alias_failures.any? { |failure| failure.include?("aliases") || failure.include?("merge keys") }
  failures << "negative fixture unexpectedly accepted YAML action indirection"
end

abort failures.join("\n") unless failures.empty?
RUBY

printf 'ok: every remote GitHub Action uses an immutable revision with a readable version comment\n'
