'
' Test function pointer arrays with Null elements (fixes #626, #562)
'
SuperStrict

Framework brl.standardio

Function func1:String(n:Int)
	Return "func1:" + n
End Function

Function func2:String(n:Int)
	Return "func2:" + n
End Function

Local f:String(n:Int)[3]

f[0] = func1
f[1] = func2
f[2] = Null

Print f[0](10)
Print f[1](20)
