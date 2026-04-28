'
' Test that function pointer assignment checks Var modifier (fixes #681)
' This should produce a compile error because F takes Int Var but x expects Int
'
SuperStrict

Framework brl.standardio

Function F(i:Int Var)
	i = 42
End Function

' This should NOT compile - Var mismatch
' Uncommenting the next line should cause a compile error:
' Local x(i:Int) = F

' This should compile - Var matches
Local y(i:Int Var) = F

Local val:Int = 10
y(val)
Print val
