# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "fileutils"

# Shared constants
COVERAGE_DIR = File.expand_path("coverage", __dir__)

RSpec::Core::RakeTask.new(:spec)

require "standard/rake"

task default: %i[spec standard]

# Coverage tasks
namespace :coverage do
  desc "Run RSpec with coverage (COVERAGE=1)"
  task :run do
    ENV["COVERAGE"] = "1"
    Rake::Task["spec"].reenable
    Rake::Task["spec"].invoke
    puts "\nCoverage report: #{File.join(COVERAGE_DIR, "index.html")}" if File.exist?(File.join(COVERAGE_DIR,
      "index.html"))
  end

  desc "Clean coverage artifacts"
  task :clean do
    if Dir.exist?(COVERAGE_DIR)
      rm_r COVERAGE_DIR
      puts "Removed #{COVERAGE_DIR}"
    else
      puts "No coverage directory to remove"
    end
  end

  desc "Clean then run coverage"
  task all: %i[clean run]

  desc "Write coverage summary.json & badge.svg (requires prior coverage:run)"
  task :summary do
    require "json"
    resultset = File.join(COVERAGE_DIR, ".resultset.json")
    unless File.exist?(resultset)
      puts "No coverage data found. Run 'rake coverage:run' first."
      next
    end
    data = JSON.parse(File.read(resultset))
    coverage_hash = data["RSpec"]["coverage"] if data["RSpec"]
    unless coverage_hash
      puts "Unexpected resultset structure, cannot find rspec.coverage"
      next
    end
    covered = 0
    total = 0
    coverage_hash.each_value do |file_cov|
      lines = file_cov["lines"]
      lines.each do |val|
        next if val.nil?

        total += 1
        covered += 1 if val > 0
      end
    end
    pct = total.positive? ? (covered.to_f / total * 100.0) : 0.0
    summary_file = File.join(COVERAGE_DIR, "summary.json")
    File.write(summary_file, JSON.pretty_generate({timestamp: Time.now.utc.iso8601, line_coverage: pct.round(2)}))
    # Badge
    color = case pct
    when 90..100 then "#4c1"
    when 80...90 then "#97CA00"
    when 70...80 then "#dfb317"
    when 60...70 then "#fe7d37"
    else "#e05d44"
    end
    badge = <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="150" height="20" role="img" aria-label="coverage: #{pct.round(2)}%">
        <linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
        <rect rx="3" width="150" height="20" fill="#555"/>
        <rect rx="3" x="70" width="80" height="20" fill="#{color}"/>
        <path fill="#{color}" d="M70 0h4v20h-4z"/>
        <rect rx="3" width="150" height="20" fill="url(#s)"/>
        <g fill="#fff" text-anchor="middle" font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="11">
          <text x="35" y="14">coverage</text>
          <text x="110" y="14">#{format("%.2f", pct)}%</text>
        </g>
      </svg>
    SVG
    # Write standard coverage/badge.svg and duplicate to badges/coverage.svg for README stability
    File.write(File.join(COVERAGE_DIR, "badge.svg"), badge)
    badges_dir = File.join("badges")
    FileUtils.mkdir_p(badges_dir)
    File.write(File.join(badges_dir, "coverage.svg"), badge)
    puts "Coverage: #{pct.round(2)}% (summary.json, coverage/badge.svg & badges/coverage.svg written)"
  end
end

# Pre-commit preparation task
desc "Run standard:fix and coverage:run (pre-commit helper)"
task prep: ["standard:fix", "coverage:run"]

desc "Alias for prep"
task pc: :prep
