# Copyright (c) 2009 Jeff Heuer
# 
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
# 
# Except as contained in this notice, the name(s) of the above 
# copyright holders shall not be used in advertising or otherwise 
# to promote the sale, use or other dealings in this Software 
# without prior written authorization.

require 'rubygems'
require 'hpricot'
require 'open-uri'

class ResultSet
  # TODO
  class << self; attr_accessor :sleep_seconds_between_github_requests end
  @sleep_seconds_between_github_requests = 15

  attr_accessor :user, :repo, :commit_sha, :score, :filename
  
  def self.load_from_cache
    Dir.glob('results/results.*.txt').collect { |f|
      ResultSet.new($1, $2, $3, $4.to_i) if f =~ /^results\/results\.(\w+)\.(.+)\.(\w+)\.(\d+)\.txt/
    }.compact
  end
  
  def self.get_for_contest_repo(user, repo)
    scores_table = Hpricot(open("http://contest.github.com/p/#{user}/#{repo}")).at('h2[text()="Scores"]').next_sibling
    puts "  sleeping for #{@sleep_seconds_between_github_requests} secs..."
    sleep @sleep_seconds_between_github_requests
    (scores_table/'tr').collect do |tr|
      ResultSet.new(
        user, 
        repo, 
        tr.at('td:last-of-type a')[:href].split('/').last, 
        tr.at('td:eq(1) strong').inner_text.to_i
      )
    end
  end
  
  def initialize(user, repo, commit_sha, score)
    @user = user
    @repo = repo
    @commit_sha = commit_sha
    @score = score
  end
  
  def to_s
    "#{@user}/#{@repo}, score: #{@score}"
  end
  
  def to_s_with_commit
    "#{@user}/#{@repo}/#{@commit_sha}, score: #{@score}"
  end
  
  def filename
    "results/results.#{@user}.#{@repo}.#{@commit_sha}.#{@score}.txt"  
  end
  
  # Return array of hashes
  def results
    # TODO: cache
    repo_recs = []
    raw_results.each_line do |line|
      user, repos = line.split(':')
      repos.chomp.split(',').uniq.each { |r| repo_recs << [user, r] } unless repos.nil?
    end
    repo_recs    
  end
  
  def results_as_user_hash
    results = {}
    raw_results.each_line do |line|
      user, repos = line.split(':')
      results[user] = repos.chomp.split(',').uniq unless repos.nil?
    end
    results
  end
  
  def raw_results
    if File.exists?(filename)
      results = File.open(filename, 'r')
#      puts "    using existing data..."
    else
      begin
        commit_doc = get_hpricot_doc("http://github.com/api/v2/xml/commits/show/#{user}/#{repo}/#{commit_sha}")
        latest_commit_tree_sha = commit_doc.at('commit:first/tree').inner_text
        puts "    fetching results.txt from tree: #{latest_commit_tree_sha}"
        results_doc = get_hpricot_doc("http://github.com/api/v2/xml/blob/show/#{user}/#{repo}/#{latest_commit_tree_sha}/results.txt")
        results = results_doc.at('data').inner_text
        File.open(filename, 'w') {|f| f.write(results.to_s)}
      rescue OpenURI::HTTPError
        puts "    HTTPError fetching #{filename}" and return nil
      rescue RuntimeError
        puts "    RuntimeError fetching #{filename}" and return nil
      rescue Net::HTTPBadResponse
        puts "    HTTPBadResponse fetching #{filename}" and return nil
      end
    end

    results
  end
  
  def get_hpricot_doc(url)
    Hpricot.XML(open(url))
    puts "  sleeping for #{@sleep_seconds_between_github_requests} secs..." and sleep @sleep_seconds_between_github_requests
  end

end