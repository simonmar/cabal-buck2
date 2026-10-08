{
module Parser (parse) where
}

%name parse
%tokentype { Char }
%token c { _ }

%%

E : c { () }
