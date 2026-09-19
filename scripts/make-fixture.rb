#!/usr/bin/env ruby
# A disposable, real Git comparison for visual checks and performance measurements.
require 'tmpdir'
require 'fileutils'
root = Dir.mktmpdir('slopdiff-fixture-')
Dir.chdir(root) do
  def git(*args)
    system('git', *args, out: File::NULL) || abort("git #{args.join(' ')} failed")
  end
  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
  git('init', '-b', 'main')
  git('config', 'user.name', 'Slopdiff Fixture')
  git('config', 'user.email', 'fixture@localhost')
  write('.gitignore', "ignored/\n")
  write('src/review/ReviewSession.kt', <<~KOTLIN)
    package dev.slopdiff.review

    import kotlin.time.Clock
    import kotlin.time.Instant
    import kotlinx.coroutines.flow.MutableStateFlow
    import kotlinx.coroutines.flow.StateFlow
    import kotlinx.coroutines.flow.asStateFlow

    data class ReviewComment(
        val path: String,
        val firstLine: Int,
        val lastLine: Int,
        val body: String,
    )

    class ReviewSession(private val repository: Repository) {
        private val comments = MutableStateFlow<List<ReviewComment>>(emptyList())
        val reviewComments: StateFlow<List<ReviewComment>> = comments.asStateFlow()

        suspend fun finishReview(): String {
            val snapshot = repository.currentSnapshot()
            return comments.value.joinToString("\\n") { it.body }
        }

        fun addComment(comment: ReviewComment) {
            comments.value = comments.value + comment
        }
    }
  KOTLIN
  write('src/review/Formatting.kt', "package example\n\nval count = 1\n")
  write('src/review/HorizontalScroll.kt', "package dev.slopdiff.review\n\nval explanation = \"#{'Original content that must remain reachable on the left. ' * 14}\"\n")
  write('src/legacy/OldReview.kt', "class OldReview {\n    fun obsolete() = Unit\n}\n")
  write('docs/review.md', "# Reviewing an agent's work\n\nA small review tool.\n")
  write('assets/example.bin', "\x00\x01OLD")
  git('add', '.')
  git('commit', '-m', 'Fixture base')
  git('switch', '-c', 'agent/review-session')
  text = File.read('src/review/ReviewSession.kt')
  text.sub!('import kotlin.time.Clock', "import java.nio.file.Path\nimport kotlin.time.Clock")
  text.sub!('return comments.value.joinToString("\\n") { it.body }', <<~CODE.chomp)
    return ReviewMarkdown.export(
                comparison = snapshot.comparison,
                comments = comments.value,
                reviewedAt = Clock.System.now(),
            )
  CODE
  text.sub!('comments.value = comments.value + comment', <<~CODE.chomp)
    require(comment.firstLine > 0) { "Line numbers start at one" }
            require(comment.lastLine >= comment.firstLine) { "Invalid line range" }
            comments.value = comments.value + comment
  CODE
  write('src/review/ReviewSession.kt', text)
  write('src/review/Formatting.kt', "package example\n\nval count  =  1\n")
  write('src/review/HorizontalScroll.kt', "package dev.slopdiff.review\n\nval explanation = \"#{'Changed content that must remain reachable on the right. ' * 18}\"\n")
  git('rm', 'src/legacy/OldReview.kt')
  write('docs/review.md', <<~MD)
    # Reviewing an agent's work

    Keep your attention on **production code**.

    ## A short review loop

    1. Open a branch comparison.
    2. Select a line and leave a comment.
    3. Copy your review back to the agent.

    | Category | Behavior |
    | --- | --- |
    | Production | Review first |
    | Tests | Fold by default |

    ```kotlin
    val review = session.finishReview()
    clipboard.copy(review)
    ```

    > No branch switching. No publishing.

    <script>alert("raw HTML must be inert")</script>
  MD
  write('assets/example.bin', "\x00\x01NEW")
  write('tests/ReviewSessionTest.kt', "import kotlin.test.Test\n\nclass ReviewSessionTest {\n    @Test fun exportsReview() = Unit\n}\n")
  write('package-lock.json', "{\"lockfileVersion\": 3}\n")
  write('schema/review.proto', "syntax = \"proto3\";\nmessage Comment {\n  string path = 1;\n  string body = 2;\n}\n")
  write('src/notes.txt', "This arbitrary text file stays visible.\n")
  write('src/typescript/review.ts', "import {\n  Review,\n  Comment,\n} from './models';\n\nexport const finish = (review: Review): string => review.comments.join('\\n');\n")
  write('src/python/review.py', "from typing import (\n    Iterable,\n    Sequence,\n)\n\ndef export(comments: Sequence[str]) -> str:\n    return '\\n'.join(comments)\n")
  write('src/rust/review.rs', "use std::{\n    path::PathBuf,\n    collections::HashMap,\n};\n\npub fn review() -> usize {\n    42\n}\n")
  write('src/go/review.go', "package review\n\nimport (\n    \"fmt\"\n    \"strings\"\n)\n\nfunc Export(body string) string {\n    return strings.TrimSpace(body)\n}\n")
  write('src/java/Review.java', "import java.util.List;\nimport java.util.ArrayList;\n\npublic class Review {\n    public int count() { return 42; }\n}\n")
  if ARGV.include?('--stress')
    386.times do |index|
      body = "package example.feature#{index}\n\n"
      25.times { |n| body += "fun operation#{n}(input: String): String {\n    return input.trim() + \"#{index}:#{n}\"\n}\n" }
      write("src/stress/Feature#{format('%03d', index)}.kt", body)
    end
  end
  git('add', '.')
  git('commit', '-m', 'Agent implementation')
  write('src/review/Uncommitted.kt', "package dev.slopdiff.review\n\nfun uncommitted() = \"Included in the review\"\n")
  write('ignored/secret.txt', "Must not appear\n")
end
puts root
