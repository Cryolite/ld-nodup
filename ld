#! /usr/bin/ruby1.9.1

# Requires Ruby 1.9.x.
# This script can't run on Ruby 1.8.x (because of http://bit.ly/xJi5ro)
# nor Windows (because Open3 can't work).

# If this script is invoked without `--nodup' command line option, it just
# invokes `ld' command. All the command line options are passed to `ld' as
# they are. Finally, this script exits and returns ld's status code.
#
# If this script is invoked with `--nodup' command line option, it invokes
# `gold' linker (http://bit.ly/ylAh5N) with `--debug files' command line
# option. All the command line options other than `--nodup' are passed to
# `gold' as they are. If `gold' fails, then this script also fails and
# immediately exits with the error status code. If `gold' succeeds in linking
# and produces the result of linking, the subsequent behavior of this script
# is as follows.
#
# With `--debug files' option, `gold' outputs the file paths it attempts to
# open to `stderr'. This script analyzes `stderr' and enumerates all the file
# paths. These files are ones that are directly passed to `gold' as the
# command line options or searched by `-l' options.
#
# Next, this script musters all global symbols defined in the enumerated
# files by using `nm -g' command on each file.
#
# If any duplicate symbol is found, this script prints the duplicate symbols
# to `stderr', deletes the result of linking produced by `gold' and exits
# with an error status code.
#
# If no duplicate symbol is found, this script just exits with the success
# status code.

require 'open3'

# The full path to GNU ld.
LD_FULL_PATH = '/usr/bin/ld'

# The full path to gold linker.
GOLD_FULL_PATH = '/usr/bin/gold'

# The line pattern from `ld --debug files'. `$1' should match the file path.
GOLD_FILE_PATH_PATTERN = /^#{GOLD_FULL_PATH}: Attempt to open (.*?) succeeded$/





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

# Prepares the link command and options.
link_command = nil
if is_nodup then
  link_command = "#{GOLD_FULL_PATH} --debug files"
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
# Outputs by `--debug files' option will be written to `stderr'.
linker_out, linker_err, linker_status = Open3.capture3(link_command)
# Print the standard output from the linker.
print linker_out
if !is_nodup || !linker_status.success? then
  # Exits immediately if '--nodup' was not specified or the linking failed.
  STDERR.print linker_err
  exit linker_status.to_i
end

# List containing the paths of already scanned files.
files = Hash.new

# List containing the symbols whose definition is already found.
symbols = Hash.new

# List containing the symbols of no interest.
special_symbols = {'_init' => nil, '_fini' => nil}

# Status code to be returned from this script.
status = 0

linker_err.each_line {|linker_line|
  linker_line.chomp!

  if GOLD_FILE_PATH_PATTERN !~ linker_line then
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

  # `gold --debug files' could output the path to a library file multiple
  # times, e.g., each of which is for an objct file contained in an archive
  # file. So, skips the second and subsequent outputs of the same path.
  if files.has_key?(file_path) then
    next
  end
  files.store(file_path, true)

  # Executes `nm -g' command.
  nm_out, nm_err, nm_status = Open3.capture3("nm -g \"#{file_path}\"")
  if !nm_status.success? then
    #print nm_out
    #STDERR.print nm_err
    next
  end

  #if /no symbols/ =~ nm_out then
  #  print nm_out
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
          STDERR.puts "ERROR: #{file_path}: #{symbol}: multiple definitions in the text section"
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
