These are errors I am not sure how to trigger since they mix
tokens from different lexing rules:

Menhir focuses on "year" for triggering an error, though these errors are
related to the "law" and "directive" lexing rules that cannot produce a "year"
token.
