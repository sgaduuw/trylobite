//! Parsing: tokens into the commands they make, as POSIX's shell grammar
//! has them, kept reasonable.
//!
//! A list is and-or lists separated by ; & or newlines, & running the
//! one before it in the background. An and-or list is pipelines joined by
//! && and ||; a pipeline is commands joined by |, perhaps after a !. A
//! command is simple (assignments, words and redirections), compound
//! (if, while, until, for, case, { list; } and ( list ), each perhaps
//! with redirections after it), or a function's definition, NAME() and
//! a compound command. The reserved words (if then elif else fi while
//! until do done for in case esac { } !) count only unquoted, where a
//! command's name could stand.

use alloc::rc::Rc;
use trystd::prelude::*;

use crate::lex::{Kind, Redir, Tok};

pub type List = Vec<Item>;

/// An and-or list, and whether & ends it.
pub struct Item {
    pub first: Pipeline,
    /// Each next pipeline, and whether && (or else ||) comes before it.
    pub rest: Vec<(bool, Pipeline)>,
    pub background: bool,
}

pub struct Pipeline {
    /// ! before it: its status is negated.
    pub bang: bool,
    pub cmds: Vec<Command>,
}

pub struct Command {
    pub node: Node,
    /// A simple command's redirections, or those after a compound one.
    pub redirs: Vec<Redirect>,
}

pub struct Redirect {
    pub fd: i32,
    pub how: Redir,
    /// The file, as typed; >&N's N.
    pub target: Tok,
}

pub enum Node {
    /// Assignments and words, in order: the assignments are the words
    /// before the first that is not one.
    Simple(Vec<Tok>),
    /// if/elif arms (a condition and its body), then else's body.
    If(Vec<(List, List)>, Option<List>),
    /// while or until (true): the condition, then the body.
    Loop(bool, List, List),
    /// for NAME [in WORD...]: without in, the positional parameters.
    For(Vec<u8>, Option<Vec<Tok>>, List),
    /// case WORD in PATTERN|PATTERN) LIST ;; ... esac
    Case(Tok, Vec<(Vec<Tok>, List)>),
    /// { list; } or ( list ): run in the shell either way.
    Group(List),
    /// NAME() COMMAND
    Function(Vec<u8>, Rc<Command>),
}

/// Why tokens do not make a command.
pub enum Error {
    /// They end before the command does: more lines may finish it.
    Incomplete,
    /// They cannot make one: the token at fault, by its line, and what
    /// the shell says.
    Syntax(u32, Vec<u8>),
}

const RESERVED: &[&[u8]] = &[
    b"if", b"then", b"elif", b"else", b"fi", b"while", b"until", b"do", b"done", b"for", b"in",
    b"case", b"esac", b"{", b"}", b"!",
];

/// Words that end a list where a command's name would stand.
const ENDS: &[&[u8]] = &[b"then", b"elif", b"else", b"fi", b"do", b"done", b"esac", b"}"];

pub struct Parser {
    toks: Vec<Tok>,
    at: usize,
}

impl Parser {
    pub fn new(toks: Vec<Tok>) -> Parser {
        Parser { toks, at: 0 }
    }

    fn peek(&self) -> Option<&Tok> {
        self.toks.get(self.at)
    }

    fn peek_kind(&self) -> Option<Kind> {
        self.peek().map(|t| t.kind)
    }

    /// Whether the next token is the reserved word `w`.
    fn at_word(&self, w: &[u8]) -> bool {
        self.peek().is_some_and(|t| t.is(w))
    }

    fn take(&mut self) -> Option<Tok> {
        let t = self.toks.get(self.at).cloned();
        self.at += 1;
        t
    }

    /// The error for the token at hand: incomplete at the end.
    fn unexpected<T>(&self) -> Result<T, Error> {
        match self.peek() {
            None => Err(Error::Incomplete),
            Some(t) => {
                let mut said = b"sh: unexpected ".to_vec();
                said.extend_from_slice(match t.kind {
                    Kind::Word => &t.text,
                    Kind::Newline => b"end of line",
                    Kind::Pipe => b"|",
                    Kind::OrIf => b"||",
                    Kind::Amp => b"&",
                    Kind::AndIf => b"&&",
                    Kind::Semi => b";",
                    Kind::DSemi => b";;",
                    Kind::LParen => b"(",
                    Kind::RParen => b")",
                    Kind::Redir(_) => b"redirection",
                });
                Err(Error::Syntax(t.line, said))
            }
        }
    }

    fn newlines(&mut self) {
        while self.peek_kind() == Some(Kind::Newline) {
            self.at += 1;
        }
    }

    fn expect(&mut self, w: &[u8]) -> Result<(), Error> {
        self.newlines();
        if self.at_word(w) {
            self.at += 1;
            Ok(())
        } else {
            self.unexpected()
        }
    }

    /// The next command line: and-or lists up to a newline, or the end.
    /// None once the tokens are used up.
    pub fn next_line(&mut self) -> Result<Option<List>, Error> {
        self.newlines();
        if self.peek().is_none() {
            return Ok(None);
        }
        let list = self.list(true)?;
        match self.peek_kind() {
            None | Some(Kind::Newline) => Ok(Some(list)),
            _ => self.unexpected(),
        }
    }

    /// A list: up to a word in ENDS, a ) or ;;, or with `line` a newline.
    fn list(&mut self, line: bool) -> Result<List, Error> {
        let mut items = Vec::new();
        loop {
            if !line {
                self.newlines();
            }
            match self.peek() {
                None => return Ok(items),
                Some(t) if t.kind == Kind::RParen || t.kind == Kind::DSemi => return Ok(items),
                Some(t) if t.kind == Kind::Word && ENDS.iter().any(|w| t.is(w)) => return Ok(items),
                Some(t) if line && t.kind == Kind::Newline => return Ok(items),
                _ => {}
            }
            let mut item = self.and_or()?;
            let sep = match self.peek_kind() {
                Some(Kind::Amp) => {
                    item.background = true;
                    true
                }
                Some(Kind::Semi) => true,
                Some(Kind::Newline) => !line,
                _ => false,
            };
            if sep {
                self.at += 1;
            }
            items.push(item);
            match self.peek() {
                None => {}
                Some(t) if matches!(t.kind, Kind::Newline | Kind::RParen | Kind::DSemi) => {}
                Some(t) if t.kind == Kind::Word && (sep || ENDS.iter().any(|w| t.is(w))) => {}
                Some(t) if sep && matches!(t.kind, Kind::Redir(_) | Kind::LParen) => {}
                _ => return self.unexpected(),
            }
        }
    }

    fn and_or(&mut self) -> Result<Item, Error> {
        let first = self.pipeline()?;
        let mut rest = Vec::new();
        loop {
            let and = match self.peek_kind() {
                Some(Kind::AndIf) => true,
                Some(Kind::OrIf) => false,
                _ => return Ok(Item { first, rest, background: false }),
            };
            self.at += 1;
            self.newlines();
            rest.push((and, self.pipeline()?));
        }
    }

    fn pipeline(&mut self) -> Result<Pipeline, Error> {
        let bang = self.at_word(b"!");
        if bang {
            self.at += 1;
        }
        let mut cmds = vec![self.command()?];
        while self.peek_kind() == Some(Kind::Pipe) {
            self.at += 1;
            self.newlines();
            cmds.push(self.command()?);
        }
        Ok(Pipeline { bang, cmds })
    }

    fn command(&mut self) -> Result<Command, Error> {
        let Some(t) = self.peek().cloned() else {
            return Err(Error::Incomplete);
        };
        let node = match t.kind {
            Kind::LParen => {
                self.at += 1;
                let list = self.list(false)?;
                if self.peek_kind() != Some(Kind::RParen) {
                    return self.unexpected();
                }
                self.at += 1;
                Node::Group(list)
            }
            Kind::Word if t.is(b"{") => {
                self.at += 1;
                let list = self.body_list()?;
                self.expect(b"}")?;
                Node::Group(list)
            }
            Kind::Word if t.is(b"if") => self.if_()?,
            Kind::Word if t.is(b"while") || t.is(b"until") => {
                self.at += 1;
                let cond = self.body_list()?;
                self.expect(b"do")?;
                let body = self.body_list()?;
                self.expect(b"done")?;
                Node::Loop(t.is(b"until"), cond, body)
            }
            Kind::Word if t.is(b"for") => self.for_()?,
            Kind::Word if t.is(b"case") => self.case()?,
            Kind::Word if self.toks.get(self.at + 1).is_some_and(|n| n.kind == Kind::LParen)
                && self.toks.get(self.at + 2).is_some_and(|n| n.kind == Kind::RParen) =>
            {
                // NAME() COMMAND
                if !crate::vars::is_name(&t.text) || RESERVED.iter().any(|w| t.is(w)) {
                    return self.unexpected();
                }
                self.at += 3;
                self.newlines();
                let body = self.command()?;
                if matches!(body.node, Node::Simple(_)) {
                    return Err(Error::Syntax(t.line, b"sh: a function's body is a compound command".to_vec()));
                }
                return Ok(Command { node: Node::Function(t.text.clone(), Rc::new(body)), redirs: Vec::new() });
            }
            Kind::Word | Kind::Redir(_) => return self.simple(),
            _ => return self.unexpected(),
        };
        let mut redirs = Vec::new();
        while let Some(Kind::Redir(_)) = self.peek_kind() {
            redirs.push(self.redirect()?);
        }
        Ok(Command { node, redirs })
    }

    /// The list inside a compound command, which must hold a command.
    fn body_list(&mut self) -> Result<List, Error> {
        let list = self.list(false)?;
        if list.is_empty() {
            return self.unexpected();
        }
        Ok(list)
    }

    fn redirect(&mut self) -> Result<Redirect, Error> {
        let Some(t) = self.take() else { return Err(Error::Incomplete) };
        let Kind::Redir(how) = t.kind else { unreachable!() };
        let target = if how == Redir::Dup {
            if t.text.is_empty() {
                return Err(Error::Syntax(t.line, b"sh: >& needs a descriptor, 0 to 2".to_vec()));
            }
            t.clone()
        } else {
            match self.peek() {
                Some(w) if w.kind == Kind::Word => self.take().unwrap_or(t.clone()),
                None => return Err(Error::Incomplete),
                Some(_) => return Err(Error::Syntax(t.line, b"sh: which file?".to_vec())),
            }
        };
        Ok(Redirect { fd: t.fd as i32, how, target })
    }

    fn simple(&mut self) -> Result<Command, Error> {
        let mut words = Vec::new();
        let mut redirs = Vec::new();
        loop {
            match self.peek_kind() {
                Some(Kind::Word) => {
                    let t = self.take().unwrap();
                    words.push(t);
                }
                Some(Kind::Redir(_)) => redirs.push(self.redirect()?),
                _ => break,
            }
        }
        Ok(Command { node: Node::Simple(words), redirs })
    }

    fn if_(&mut self) -> Result<Node, Error> {
        self.at += 1; // if
        let mut arms = Vec::new();
        loop {
            let cond = self.body_list()?;
            self.expect(b"then")?;
            let body = self.body_list()?;
            arms.push((cond, body));
            self.newlines();
            if self.at_word(b"elif") {
                self.at += 1;
                continue;
            }
            let els = if self.at_word(b"else") {
                self.at += 1;
                Some(self.body_list()?)
            } else {
                None
            };
            self.expect(b"fi")?;
            return Ok(Node::If(arms, els));
        }
    }

    fn for_(&mut self) -> Result<Node, Error> {
        self.at += 1; // for
        let name = match self.take() {
            Some(t) if t.kind == Kind::Word && crate::vars::is_name(&t.text) => t.text,
            Some(_) => {
                self.at -= 1;
                return self.unexpected();
            }
            None => return Err(Error::Incomplete),
        };
        // An optional ; or newlines, then in WORDS, or do.
        if self.peek_kind() == Some(Kind::Semi) {
            self.at += 1;
        }
        self.newlines();
        let mut words = None;
        if self.at_word(b"in") {
            self.at += 1;
            let mut ws = Vec::new();
            while let Some(t) = self.peek() {
                if t.kind != Kind::Word {
                    break;
                }
                ws.push(self.take().unwrap());
            }
            match self.peek_kind() {
                Some(Kind::Semi) | Some(Kind::Newline) => self.at += 1,
                None => return Err(Error::Incomplete),
                _ => return self.unexpected(),
            }
            words = Some(ws);
        }
        self.expect(b"do")?;
        let body = self.body_list()?;
        self.expect(b"done")?;
        Ok(Node::For(name, words, body))
    }

    fn case(&mut self) -> Result<Node, Error> {
        self.at += 1; // case
        let word = match self.take() {
            Some(t) if t.kind == Kind::Word => t,
            Some(_) => {
                self.at -= 1;
                return self.unexpected();
            }
            None => return Err(Error::Incomplete),
        };
        self.expect(b"in")?;
        let mut arms = Vec::new();
        loop {
            self.newlines();
            if self.at_word(b"esac") {
                self.at += 1;
                return Ok(Node::Case(word, arms));
            }
            if self.peek_kind() == Some(Kind::LParen) {
                self.at += 1;
            }
            let mut patterns = Vec::new();
            loop {
                match self.take() {
                    Some(t) if t.kind == Kind::Word => patterns.push(t),
                    None => return Err(Error::Incomplete),
                    Some(_) => {
                        self.at -= 1;
                        return self.unexpected();
                    }
                }
                match self.take().map(|t| t.kind) {
                    Some(Kind::Pipe) => continue,
                    Some(Kind::RParen) => break,
                    None => return Err(Error::Incomplete),
                    Some(_) => {
                        self.at -= 1;
                        return self.unexpected();
                    }
                }
            }
            let body = self.list(false)?;
            arms.push((patterns, body));
            self.newlines();
            if self.peek_kind() == Some(Kind::DSemi) {
                self.at += 1;
            } else if !self.at_word(b"esac") {
                return self.unexpected();
            }
        }
    }
}
