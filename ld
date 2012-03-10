#! /usr/bin/ruby1.9.1

# Requires Ruby 1.9.x.
# This script can't run on Ruby 1.8.x (because of http://bit.ly/xJi5ro)
# nor Windows (because Open3 can't work).

# This script is designed to be named `ld' or `real-ld' and invoked by GCC
# front end instead of the original `ld'. Unless this script is invoked with
# a certain command line option, this script acts as if it were the original
# `ld'. Users are requested to adjust `PATH' environment variable etc. in
# order for this script to have priority over the original `ld'.
#
# For your convenience, I summarize below the file names of `ld' GCC front
# end (more specifically, `collect2', which is a subprogram called by GCC
# front end) tries to find:
#
#   - If GCC being used was configured with `--with-ld=/path/to/ld' option,
#     the specified path is used.
#   - `real-ld' in the directories listed in the compiler's search
#     directories (including ones specified by `-B' option etc.).
#   - `real-ld' in the directories listed in `PATH' environment variable.
#   - If `REAL_LD_FILE_NAME' configuration macro is specified, the specified
#     path is used.
#   - `ld' in the compiler's search directories (again, including ones
#     specified by `-B' option etc.), except that `collect2' will not execute
#     itself recursively.
#   - `ld' in `PATH' environment variable.
#
#
# If you want to name this script `ld', the absolute path to the original
# `ld' should be hardcoded in this script in order to avoid self-recursive
# call. It is not the case when this script is named `real-ld'.
#
# If this script is invoked without `--nodup' command line option, it just
# calls the original `ld'. As mentioned above, the command to call the
# original `ld' is hardcoded below in the script. All the command line
# options given to this script are passed to the original `ld' as they are.
# When the original `ld' finishes running, this script exits and returns ld's
# status code.
#
# If this script is invoked with `--nodup' command line option, it calls the
# original `ld' with `-Map=/path/to/tempfile' command line option. All the
# command line options other than `--nodup' are also passed to the original
# `ld' as they are. If the original `ld' fails (returns a non-zero status
# code), then this script immediately exits and returns a non-zero status
# code. If the original `ld' finishes successfully and produces the result of
# the link, the subsequent behavior of this script is as follows.
#
# With `-Map=/path/to/tempfile' option, the original `ld' outputs the link
# map to the specified file. This script analyzes the file and extracts all
# file paths contained in the link map. These file paths are ones that are
# directly passed to the original `ld' as the command line arguments or
# searched by `-l' options.
#
# Next, this script gathers all global symbols defined in the text section
# of the extracted file paths by using `nm -g' command on each file.
#
# If any duplicate symbol is found, this script prints the duplicate symbol
# to `stderr', deletes the result of the link produced by the original `ld'
# and finally exits and returns a non-zero status code.
#
# If no duplicate symbol is found, this script exits and returns the success
# status code.
#
# In addition to the detected duplicate symbols, the standard error output
# from the original `ld' is printed to `stderr' as it is. The standard output
# from the original `ld' is printed to `stdout' as it is, too.
#
# Many duplicate symbols of no interest are also found in the way previously
# described. Current implementation skips these symbols by the following
# ad-hoc rules.
#
#   - Skips "_init"
#   - Skips "_fini"
#   - Skips symbols that match /__.*/
#

require 'tempfile'
require 'open3'

# The full path to GNU ld.
LD_FULL_PATH = '/usr/bin/ld'

# The line pattern to extract file paths from the linker map. `$1' should
# match the file path in the line.
LINK_MAP_FILE_PATH_PATTERN = /^LOAD (.*)$/





# Checks '--nodup' option and extracts the output filename.
is_nodup = false
expect_filename = false
output_filename = 'a.out'
ARGV.each {|v|
  if v == '-o' then
    expect_filename = true
    next
  end
  if expect_filename then
    output_filename = v
    expect_filename = false
    next
  end
  if /^--output=(.*)$/ =~ v then
    output_filename = $1
    next
  end
  if v == '--nodup' then
    is_nodup = true
    next
  end
}

# Creates a tempfile for the link map.
linkmap_file = Tempfile.new('linkmap')

# Prepares the link command and options.
link_command = nil
if is_nodup then
  link_command = "#{LD_FULL_PATH} -Map=#{linkmap_file.path}"
else
  link_command = LD_FULL_PATH
end
ARGV.each {|v|
  if v == '--nodup' then
    next
  end
  link_command << ' "' << v << '"'
}

# Executes the link command.
linker_out, linker_err, linker_status = Open3.capture3("#{link_command}")
print linker_out
STDERR.print linker_err
if !is_nodup || !linker_status.success? then
  # Exits immediately if '--nodup' was not specified or the linking failed.
  if linker_status.success? then
    exit 0
  end
  exit 1 #linker_status.to_i
end

# List containing the paths of already scanned files.
files = Hash.new

# List containing the symbols whose definition is already found.
symbols = Hash.new

# List containing the symbols of no interest.
special_symbols = {'_init' => nil, '_fini' => nil}

# Status code to be returned from this script.
status = 0

linkmap_file.each_line {|linkmap_line|
  linkmap_line.chomp!

  if LINK_MAP_FILE_PATH_PATTERN !~ linkmap_line then
    # Skips the line of no interest.
    next
  end
  file_path = $1
  # Normalizes the path string.
  #file_path = File.expand_path(file_path)

  # Checks the file existence.
  if !File.exist?(file_path) then
    STDERR.puts "ERROR: cannot find the file `#{file_path}'"
    exit 1
  end

  # The link map could output the path to a library file multiple times. For
  # example, it happens when a file path is passed to the linker multiple
  # times. So, we need to skip the second and subsequent outputs of the same
  # path.
  if files.has_key?(file_path) then
    next
  end
  files.store(file_path, true)

  # Executes `nm -g' command.
  nm_out, nm_err, nm_status = Open3.capture3("nm -g \"#{file_path}\"")
  if !nm_status.success? then
    # Simply skips the file on which `nm' failed. Is there any TODO?
    next
  end

  #if /no symbols/ =~ nm_out then
  #  # Skips the file that does not contain any symbol.
  #  next
  #end

  nm_out.each_line {|nm_line|
    nm_line.chomp!
    if /:$/ =~ nm_line then
      # Skips the first line, which is of no interest.
      next
    end

    if /^[[:xdigit:]]+ ([ABbCDdGgiNpRrSsTtUuVvWw\-\?]) (.*)/ =~ nm_line
      kind = $1
      symbol = $2

      if symbol =~ /^__.*/ then
        # Skips a symbol corresponding to a reserved name.
        next
      end

      if special_symbols.has_key?(symbol) then
        # Skips a special symbol, in which we don't have any interest.
        next
      end

      if kind == 'T' then
        # A global symbol in the text (code) section.
        if symbols.has_key?(symbol) then
          # Multiple definitions found.
          first_path = symbols.fetch(symbol)
          STDERR.puts "ERROR: #{file_path}: multiple definition of `#{symbol}'"
          STDERR.puts "ERROR: #{first_path}: first defined here"
          # Sets the error status code and goes to the next symbol.
          status = 1
          next
        else
          # First definition.
          symbols.store(symbol, file_path)
        end
      end
    end
  }
}

if status != 0 then
  # Deletes the result of linking when any duplicate symbol was found.
  File.delete(output_filename)
end
exit status
