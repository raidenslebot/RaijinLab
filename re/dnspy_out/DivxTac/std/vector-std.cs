using System;
using System.Runtime.CompilerServices;

namespace std
{
	// Token: 0x0200001B RID: 27
	[NativeCppClass]
	internal struct vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>
	{
		// Token: 0x06000146 RID: 326 RVA: 0x00004888 File Offset: 0x00003C88
		public unsafe static void <MarshalCopy>(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0, vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_1)
		{
			if (A_0 != null)
			{
				<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>.{ctor}(A_0, A_1);
			}
		}

		// Token: 0x06000147 RID: 327 RVA: 0x00004E74 File Offset: 0x00004274
		public unsafe static void <MarshalDestroy>(vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>* A_0)
		{
			<Module>.std.vector<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>,std::allocator<std::basic_string<char,std::char_traits<char>,std::allocator<char>\u0020>\u0020>\u0020>._Tidy(A_0);
		}
	}
}
