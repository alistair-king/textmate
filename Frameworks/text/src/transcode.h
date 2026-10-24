#include <oak/debug.h>
#include <oak/misc.h>

namespace text
{
	struct transcode_t
	{
	transcode_t (std::string fromCharset, std::string toCharset)
	{
		std::string const kBOMCharacter = "\uFEFF";

		_buffer = new char[_buffer_size];
		reset_buffer();

		bool readBOM = false;
		fromCharset = parse_charset(fromCharset, &readBOM);
		if(readBOM)
		{
			if(auto bomWriter = transcode_t("UTF-8", fromCharset))
				bomWriter(kBOMCharacter.data(), kBOMCharacter.data() + kBOMCharacter.size(), back_inserter(_skip_prefix));
		}

		bool writeBOM = false;
		toCharset = parse_charset(toCharset, &writeBOM);
		if(writeBOM)
		{
			if(auto bomWriter = transcode_t("UTF-8", toCharset))
			{
				_dest = bomWriter(kBOMCharacter.data(), kBOMCharacter.data() + kBOMCharacter.size(), _dest);
				_left = _buffer_size - (_dest - _buffer);
			}
		}

		_from_charset = fromCharset;
		_to_charset   = toCharset;
		// macOS libiconv corrupts //TRANSLIT output from the 3rd transliteration
		// performed by a single iconv_t, so for UTF-8 sources we convert each
		// non-ASCII character through a fresh descriptor (see operator() below).
		_per_char_translit = toCharset.find("//TRANSLIT") != std::string::npos && is_utf8(fromCharset);

		_handle = iconv_open(toCharset.c_str(), fromCharset.c_str());
		if(_handle == (iconv_t)-1)
			perrorf("transcode_t: iconv_open(\"%s\", \"%s\")", toCharset.c_str(), fromCharset.c_str());
	}

		~transcode_t ()
		{
			ASSERT_EQ(_left, _buffer_size);
			if(_handle != (iconv_t)-1)
				iconv_close(_handle);
			delete[] _buffer;
		}

		operator bool () const
		{
			return _handle != (iconv_t)-1;
		}

		template <typename _OutputIter>
		_OutputIter operator() (_OutputIter out)
		{
			for(auto ch : _partial_sequence)
			{
				// This asserts that the output encoding is an ASCII superset
				int bytesWritten = std::min(snprintf(_dest, _left, "\\x%02X", ch), (int)_left);
				if(bytesWritten > 0)
				{
					_dest += bytesWritten;
					_left -= bytesWritten;
				}
			}
			_partial_sequence.clear();

			out = std::copy(_buffer, _dest, out);
			reset_buffer();
			return out;
		}

		template <typename _OutputIter>
		_OutputIter operator() (char const* first, char const* last, _OutputIter out)
		{
			if(!_per_char_translit)
				return convert(first, last, out);

			while(first != last)
			{
				if(!(*first & 0x80))
				{
					char const* runEnd = first;
					while(runEnd != last && !(*runEnd & 0x80))
						++runEnd;
					out = convert(first, runEnd, out);
					first = runEnd;
				}
				else if(size_t const len = utf8_sequence_length(*first), avail = last - first; len == 0 || len > avail)
				{
					// Invalid lead byte, or truncated at end of input: let convert()
					// report it via EILSEQ or buffer it via EINVAL, like the streaming path.
					out = convert(first, first + 1, out);
					++first;
				}
				else
				{
					reopen();
					out = convert(first, first + len, out);
					first += len;
				}
			}
			return out;
		}

		template <typename _OutputIter>
		_OutputIter convert (char const* first, char const* last, _OutputIter out)
		{
			ASSERT_NE(_handle, (iconv_t)-1);

			char* inBuf      = (char*)first;
			size_t inBufLeft = last - first;

			if(_skip_offset < _skip_prefix.size())
			{
				size_t len = std::min(_skip_prefix.size() - _skip_offset, inBufLeft);
				if(std::equal(inBuf, inBuf + len, _skip_prefix.data() + _skip_offset))
				{
					_skip_offset += len;
				}
				else
				{
					size_t oldOffset = _skip_offset;
					_skip_offset = _skip_prefix.size();
					out = (*this)(_skip_prefix.data(), _skip_prefix.data() + oldOffset + len, out);
				}

				inBuf        += len;
				inBufLeft    -= len;
			}

			while(inBufLeft)
			{
				size_t rc;
				if(_partial_sequence.empty())
				{
					rc = iconv(_handle, &inBuf, &inBufLeft, &_dest, &_left);
				}
				else
				{
					do {

						_partial_sequence.append(1, *inBuf++);
						inBufLeft -= 1;

						char* partialBuf      = (char*)_partial_sequence.data();
						size_t partialBufLeft = _partial_sequence.size();

						rc = iconv(_handle, &partialBuf, &partialBufLeft, &_dest, &_left);
						_partial_sequence.erase(0, _partial_sequence.size() - partialBufLeft);

						if(rc == (size_t)-1 && errno != EINVAL)
							break;

					} while(!_partial_sequence.empty() && inBufLeft);
				}

				out = std::copy(_buffer, _dest, out);
				reset_buffer();

				if(rc == (size_t)-1)
				{
					if(errno == EINVAL)
					{
						_partial_sequence.append(inBuf, inBufLeft);
						break;
					}
					else if(errno == EILSEQ)
					{
						++_invalid_count;

						if(_partial_sequence.empty())
						{
							_partial_sequence.append(1, *inBuf++);
							--inBufLeft;
						}

						out = (*this)(out); // Force writing current partial sequence to ‘out’
					}
					else if(errno == E2BIG)
					{
						ASSERT_NE(_left, 0);
					}
					else
					{
						perror("transcode_t: iconv");
						break;
					}
				}
			}

			out = std::copy(_buffer, _dest, out);
			reset_buffer();

			return out;
		}

		size_t invalid_count () const { return _invalid_count; }

	private:
		std::string parse_charset (std::string charset, bool* bom)
		{
			std::string const kBOMOption = "//BOM";
			auto i = charset.find(kBOMOption);
			if(i != std::string::npos)
			{
				charset.erase(i, kBOMOption.size());
				if(bom)
					*bom = true;
			}
			return charset;
		}

		static bool is_utf8 (std::string const& charset)
		{
			std::string lower;
			for(char c : charset)
				lower += (c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c;
			return lower == "utf-8" || lower == "utf8";
		}

		static size_t utf8_sequence_length (char ch)
		{
			unsigned char const c = ch;
			if(c >= 0xC2 && c <= 0xDF) return 2;
			if(c >= 0xE0 && c <= 0xEF) return 3;
			if(c >= 0xF0 && c <= 0xF4) return 4;
			return 0; // continuation byte, overlong lead, or invalid lead
		}

		void reopen ()
		{
			if(_handle != (iconv_t)-1)
				iconv_close(_handle);
			_handle = iconv_open(_to_charset.c_str(), _from_charset.c_str());
		}

		void reset_buffer ()
		{
			_dest = _buffer;
			_left = _buffer_size;
		}

		iconv_t _handle = (iconv_t)-1;
		size_t _invalid_count = 0;

		std::string _from_charset, _to_charset;
		bool _per_char_translit = false;

		std::string _skip_prefix;
		size_t _skip_offset = 0;

		std::string _partial_sequence;

		char* _buffer;
		size_t _buffer_size = 4096;

		char* _dest;
		size_t _left;
	};

} /* text */
