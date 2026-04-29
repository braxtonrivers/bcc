'
' Test for-loop with array element as loop variable (fixes #578)
'
SuperStrict

Framework brl.standardio

Global intArray:Int[1]
For intArray[0] = 0 To 3
	Print intArray[0]
Next
